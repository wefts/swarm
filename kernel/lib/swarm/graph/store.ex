defmodule Swarm.Graph.Store do
  @moduledoc """
  Node and edge writes. `add_node` is a validated Ecto insert; `add_edge` is the
  atomic insert-or-increment upsert on the natural key, with the reinforcement
  guard: `seen_count` grows only from a **new distinct evidential origin**
  (workspace ADR-13), and the provenance key still dedups emission instances so a
  single event never counts twice (ADR-9 endogenous-loop guard).

  Performance: both are O(1) in graph size — single indexed-row writes (the
  upsert touches one edge row, one provenance row, one increment), never a scan
  or an app-code read-modify-write. Survives 10× nodes/edges.
  """

  alias Swarm.Graph.Contract
  alias Swarm.Graph.Node
  alias Swarm.Repo

  @typedoc "Result of `add_edge`: the edge id, its current distinct-origin count, and whether this call reinforced it (introduced a new origin)."
  @type edge_result :: %{id: integer(), seen_count: integer(), reinforced: boolean()}

  @doc "Insert a node. See `Swarm.Graph.Node` for fields; `type` is required."
  @spec add_node(map()) :: {:ok, Node.t()} | {:error, Ecto.Changeset.t()}
  def add_node(attrs) do
    Repo.transaction(fn ->
      case %Node{} |> Node.changeset(attrs) |> Repo.insert() do
        {:ok, node} ->
          emit_outbox(
            "node_added",
            "node:#{node.id}",
            %{id: node.id, type: node.type},
            "node:#{node.id}"
          )

          node

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Upsert a node by its stable identity `(type, key)` and return its id. Used by
  ingestion so re-seeing the same entity resolves to the same node rather than
  duplicating it. `:scope` defaults to `"private"` (default-deny).

  Before minting, the **reversible alias table** (swarm ADR-14 §3.2) is consulted:
  a `(type, key)` known to be an alias resolves to its canonical key, so a folded
  entity never re-fragments on the next ingest.
  """
  @spec upsert_node(String.t(), String.t(), keyword()) :: integer()
  def upsert_node(type, key, opts \\ []) when is_binary(type) and is_binary(key) do
    scope = Keyword.get(opts, :scope, "private")
    metadata = display_metadata(Keyword.get(opts, :display_key), key)

    # swarm ADR-4: validate at the boundary, fail-loud (raw-SQL path has no
    # changeset). A malformed type/scope must never reach the shared substrate.
    case Contract.validate_node(%{type: type, scope: scope}) do
      :ok ->
        :ok

      {:error, reason} ->
        raise Swarm.Graph.ContractError, {reason, type: type, scope: scope}
    end

    canonical = resolve_alias(type, key)

    sql = """
    INSERT INTO node (type, key, scope, provenance)
    VALUES ($1, $2, $3, $4::jsonb)
    ON CONFLICT (type, key) DO UPDATE
      SET updated_at = now(),
          provenance = node.provenance || $4::jsonb
    RETURNING id
    """

    %{rows: [[id]]} = Repo.query!(sql, [type, canonical, scope, metadata])
    id
  end

  @spec display_metadata(term(), String.t()) :: map()
  defp display_metadata(display_key, identity_key)
       when is_binary(display_key) and display_key != "" and display_key != identity_key do
    %{"display_key" => display_key}
  end

  defp display_metadata(_display_key, _identity_key), do: %{}

  # Consult the standing alias table (swarm ADR-14 §3.2): an aliased key resolves
  # to its canonical form before minting; an unknown key passes through unchanged.
  @spec resolve_alias(String.t(), String.t()) :: String.t()
  defp resolve_alias(type, key) do
    case Repo.query!(
           "SELECT canonical_key FROM node_alias WHERE type = $1 AND alias_key = $2",
           [type, key]
         ) do
      %{rows: [[canonical]]} -> canonical
      _ -> key
    end
  end

  @doc """
  Upsert a typed edge on the natural key `(src, type, dst, visibility_scope)`.

  Reinforcement (workspace ADR-13): `seen_count` counts **distinct evidential
  origins** and increments only when this call introduces an origin the edge has
  not seen. `provenance` is the caller-owned *emission-instance* key — re-detecting
  the same event is a no-op for the count (ADR-9 endogenous-loop guard); a fresh
  event of an **already-counted origin** is recorded (audit trail) but does **not**
  reinforce. `:origin` is the evidential source identity (connector-derived, stable
  across re-emissions); it **defaults to `provenance`** when absent — every event
  its own origin, the pre-v4 behaviour — so an N-derivatives-of-one-source caller
  passes one origin to keep corroboration honest.

  `opts`: `:scope` (default `"private"`), `:weight`, `:reliability`, `:origin`,
  `:evidence_kind` (what the assertion contributes to corroboration — default
  `"observation"`; the enrichment worker sets `"claim"`).
  """
  @spec add_edge(integer(), integer(), String.t(), String.t(), keyword()) ::
          {:ok, edge_result()} | {:error, term()}
  def add_edge(src, dst, type, provenance, opts \\ [])
      when is_integer(src) and is_integer(dst) and is_binary(type) and is_binary(provenance) do
    scope = Keyword.get(opts, :scope, "private")
    weight = Keyword.get(opts, :weight, 1.0)
    reliability = Keyword.get(opts, :reliability, 1.0)
    origin = Keyword.get(opts, :origin, provenance)
    # S1 (master plan, evidence-governance): corroboration counts distinct UPSTREAM LINEAGE, not
    # origin labels. Default derived from origin (wiki family → one `wiki` lineage — fixes the
    # `wiki:corrob` double-vote); a connector may pass an explicit `:lineage`.
    lineage = Keyword.get(opts, :lineage) || lineage_of(origin)
    evidence_kind = Keyword.get(opts, :evidence_kind, "observation")
    # ADR-17: a `has_step` edge's position in its procedure (NULL for every other
    # edge — enforced here at the write boundary, not just by convention). Set only
    # on first insert, like weight/reliability.
    step_ordinal = if type == "has_step", do: Keyword.get(opts, :step_ordinal), else: nil
    # ADR-13/ADR-17 ghost-purge: the structural id of the SOURCE node this evidence was
    # derived from (nil for non-derived edges). Lets `merge_nodes`/GC purge an edge whose
    # source is gone WITHOUT parsing the worker's `origin` string convention.
    source_node_id = Keyword.get(opts, :source_node_id)

    Repo.transaction(fn ->
      # Ghost-purge race guard (ADR-13/ADR-17, codex review) — see guard_source!/1.
      guard_source!(source_node_id)

      # swarm ADR-4: enforce the contract at the write boundary — type/scope
      # vocabulary, reliability range, and the ADR-5 visibility invariant (edge
      # scope no wider than the narrowest endpoint). Reject fail-loud; do NOT
      # silently store a leaking or malformed edge.
      {src_endpoint, dst_endpoint} = endpoint_metadata(src, dst)

      case Contract.validate_edge(
             endpoint_scope(src_endpoint),
             endpoint_scope(dst_endpoint),
             type,
             scope,
             reliability,
             provenance,
             origin,
             evidence_kind
           ) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback({:contract, reason})
      end

      case Contract.validate_relation_endpoints(type, src_endpoint, dst_endpoint) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback({:contract, reason})
      end

      edge_id =
        upsert_identity(src, dst, type, scope, weight, reliability, evidence_kind, step_ordinal)

      case record_event(edge_id, provenance, origin, lineage, source_node_id) do
        :new_lineage ->
          # A new distinct lineage adds exactly 1 to count(DISTINCT lineage).
          seen = bump_seen(edge_id)

          emit_outbox(
            "edge_reinforced",
            "edge:#{edge_id}",
            %{id: edge_id, src: src, dst: dst, type: type, seen_count: seen},
            "edge:#{edge_id}:#{provenance}"
          )

          %{id: edge_id, seen_count: seen, reinforced: true}

        # Fresh event under an already-counted origin, or a duplicate event:
        # recorded (or no-op) but corroboration does not grow.
        _ ->
          %{id: edge_id, seen_count: current_seen(edge_id), reinforced: false}
      end
    end)
  end

  @doc """
  Apply external ground-truth reward to a trace (T12, reward-gated persistence).
  `reward < 0` **refutes** the trace — `Swarm.Graph.GC` then reaps it regardless of
  strength, so a refuted/hallucinated trace cannot linger as ground for the next
  worker. `reward >= 0` lets it persist on the normal decay schedule.
  """
  @spec set_reward(integer(), number()) :: :ok
  def set_reward(edge_id, reward) when is_integer(edge_id) and is_number(reward) do
    Repo.query!("UPDATE edge SET reward = $2 WHERE id = $1", [edge_id, reward])
    :ok
  end

  @doc """
  Entity resolution (swarm ADR-13 layer 2 + ADR-14 §3.2): merge the `alias_key`
  node into the `into_key` node of the same `type`, **provenance- and
  span-preserving, scope-aware**.

  - **Edges** touching the alias are re-pointed onto the canonical node; a
    natural-key collision unions the alias edge's distinct provenance into the
    survivor and recomputes `seen_count` (corroboration aggregates, never
    double-counts); merge-induced self-loops drop.
  - **Chunks** are **unioned** under the surviving `node_id` (never dropped) with
    ordinals offset past the survivor's, and `node.vec` is re-aggregated from the
    unioned span set.
  - **Content** survivorship keeps the higher-fidelity body (longer body wins;
    the loser's spans already survived via the chunk union).
  - A successful merge **records the alias** in the standing table, so the next
    ingest of `alias_key` resolves straight to the canonical node.

  Guards: a **cross-scope merge is refused** (`:refused_cross_scope`) — the
  surviving node's scope is never silently widened; it is surfaced for operator
  escalation, never applied automatically. If the canonical node does not exist
  yet the alias is renamed to the canonical key (a redirect target seen before its
  page) and the alias recorded. Distinct provenance still counts distinct
  evidential origins (ADR-9), so a merge cannot let duplicate keys over-corroborate.
  Returns the surviving node id and how many alias edges were re-pointed/merged.
  """
  @spec merge_nodes(String.t(), String.t(), String.t()) ::
          {:ok, %{into_id: integer() | nil, edges: non_neg_integer(), result: atom()}}
  def merge_nodes(type, alias_key, into_key)
      when is_binary(type) and is_binary(alias_key) and is_binary(into_key) do
    Repo.transaction(fn ->
      alias_id = node_id(type, alias_key)
      into_id = node_id(type, into_key)

      cond do
        is_nil(alias_id) ->
          %{into_id: into_id, edges: 0, result: :noop_no_alias}

        alias_key == into_key or alias_id == into_id ->
          %{into_id: into_id, edges: 0, result: :noop_same}

        merge_blocked?(type, alias_key, into_key) ->
          # S4 do-not-merge: an explicit assertion that these are DISTINCT entities. Never merge
          # (a wrong merge is catastrophic + hard to un-merge); surface for escalation.
          emit_outbox(
            "merge_refused",
            "node:#{into_id || alias_id}",
            %{into: into_id, from: alias_id, reason: "do_not_merge"},
            "merge_refused:do_not_merge:#{type}:#{alias_key}->#{into_key}"
          )

          %{into_id: into_id, edges: 0, result: :refused_do_not_merge}

        is_nil(into_id) ->
          # Canonical not yet present: rename the alias to the canonical key. This
          # still changes inferred endpoint kind (`net:host:*` vs `net:address:*`),
          # so existing governed edges must validate against the proposed key before
          # the UPDATE. A merge operation that cannot be expressed safely should fail
          # loudly, not strand illegal structure behind a convenient rename.
          validate_rename_endpoints!(alias_id, into_key)

          Repo.query!("UPDATE node SET key = $2, updated_at = now() WHERE id = $1", [
            alias_id,
            into_key
          ])

          record_alias(type, alias_key, into_key)
          %{into_id: alias_id, edges: 0, result: :renamed}

        cross_scope?(alias_id, into_id) ->
          # ADR-14 §3.2: a private↔public merge is refused, never automatic. The
          # surviving scope is never silently widened; surface for escalation.
          emit_outbox(
            "merge_refused",
            "node:#{into_id}",
            %{into: into_id, from: alias_id, reason: "cross_scope"},
            "merge_refused:#{alias_id}->#{into_id}"
          )

          %{into_id: into_id, edges: 0, result: :refused_cross_scope}

        true ->
          # Serialise against concurrent merges/ingest touching these nodes: lock
          # both rows FOR UPDATE (conflicts with add_edge's FOR SHARE endpoint read),
          # closing the existing_edge→UPDATE race that could violate the edge unique
          # key (consilium/codex). Same TOCTOU class ADR-4 documents.
          Repo.query!("SELECT id FROM node WHERE id = ANY($1) FOR UPDATE", [[alias_id, into_id]])
          n = repoint_edges(alias_id, into_id)
          # schema v13: validity intervals key supersession by endpoint ids — repointed edges
          # must be re-keyed or later supersession misses them.
          Swarm.Graph.Temporal.rekey_node(into_id)
          union_chunks(alias_id, into_id)
          survive_content(alias_id, into_id)
          purge_source_edges(alias_id)
          Repo.query!("DELETE FROM node WHERE id = $1", [alias_id])
          reaggregate_vec(into_id)
          record_alias(type, alias_key, into_key)

          emit_outbox(
            "node_merged",
            "node:#{into_id}",
            %{into: into_id, from: alias_id},
            "merge:#{alias_id}->#{into_id}"
          )

          %{into_id: into_id, edges: n, result: :merged}
      end
    end)
  end

  # True iff the two nodes carry different visibility scopes (cross-scope merge).
  @spec cross_scope?(integer(), integer()) :: boolean()
  defp cross_scope?(alias_id, into_id) do
    %{rows: rows} =
      Repo.query!("SELECT id, scope FROM node WHERE id = ANY($1)", [[alias_id, into_id]])

    by_id = Map.new(rows, fn [id, scope] -> {id, scope} end)
    Map.get(by_id, alias_id) != Map.get(by_id, into_id)
  end

  # Union the alias's chunk spans under the survivor (never dropped): offset their
  # ordinals past the survivor's max so the (node_id, ordinal) key never collides.
  #
  # A chunk is self-contained — it carries its own `text` + `vec`, NOT an offset into
  # `content.body` — so unioning spans across bodies corrupts nothing at retrieval
  # time (each span is scored independently). The one documented limitation: after a
  # near-dup merge the survivor's single (higher-fidelity) body no longer regenerates
  # the full unioned span set, so a later re-segmentation (the write-amplification
  # path) would drop the alias-origin spans. Acceptable because merges target
  # near-duplicates (bodies near-identical); a future re-embed reconciles. (Raised by
  # the gemini critic on a span-offset assumption that does not hold here; codex did
  # not flag it — see board/journal.md.)
  @spec union_chunks(integer(), integer()) :: :ok
  defp union_chunks(alias_id, into_id) do
    Repo.query!(
      """
      UPDATE chunk
         SET node_id = $2,
             ordinal = ordinal + 1 +
               COALESCE((SELECT max(ordinal) FROM chunk WHERE node_id = $2), -1)
       WHERE node_id = $1
      """,
      [alias_id, into_id]
    )

    :ok
  end

  # Content survivorship: keep the higher-fidelity body (longer wins). If the
  # survivor has none, adopt the alias's; otherwise drop the alias's body (its
  # spans already survived the chunk union). Content CASCADE-drops with the node,
  # so an un-adopted alias row is reaped when the alias node is deleted.
  @spec survive_content(integer(), integer()) :: :ok
  defp survive_content(alias_id, into_id) do
    alias_len = body_len(alias_id)
    into_len = body_len(into_id)

    cond do
      alias_len == 0 ->
        :ok

      into_len == 0 ->
        Repo.query!("UPDATE content SET node_id = $2 WHERE node_id = $1", [alias_id, into_id])

      alias_len > into_len ->
        Repo.query!("DELETE FROM content WHERE node_id = $1", [into_id])
        Repo.query!("UPDATE content SET node_id = $2 WHERE node_id = $1", [alias_id, into_id])

      true ->
        :ok
    end

    :ok
  end

  @spec body_len(integer()) :: non_neg_integer()
  defp body_len(node_id) do
    case Repo.query!("SELECT length(body) FROM content WHERE node_id = $1", [node_id]) do
      %{rows: [[len]]} when is_integer(len) -> len
      _ -> 0
    end
  end

  # Re-aggregate node.vec from the (now unioned) chunk set — the mean over chunk
  # vectors (pgvector `avg`). No-op when the node has no embedded chunks.
  @spec reaggregate_vec(integer()) :: :ok
  defp reaggregate_vec(into_id) do
    Repo.query!(
      """
      UPDATE node
         SET vec = sub.v, updated_at = now()
        FROM (SELECT avg(vec) AS v FROM chunk WHERE node_id = $1 AND vec IS NOT NULL) sub
       WHERE node.id = $1 AND sub.v IS NOT NULL
      """,
      [into_id]
    )

    :ok
  end

  # Record a standing alias so the next ingest of `alias_key` resolves to the
  # canonical node. Idempotent on the (type, alias_key) PK.
  @spec record_alias(String.t(), String.t(), String.t()) :: :ok
  defp record_alias(type, alias_key, canonical_key) do
    Repo.query!(
      """
      INSERT INTO node_alias (type, alias_key, canonical_key)
      VALUES ($1, $2, $3)
      ON CONFLICT (type, alias_key) DO UPDATE SET canonical_key = $3
      """,
      [type, alias_key, canonical_key]
    )

    :ok
  end

  @doc """
  Assert (durably) that `(type, k1)` and `(type, k2)` are DISTINCT entities and must NEVER be
  merged (master-plan S4 do-not-merge). `merge_nodes/3` then refuses this pair
  (`:refused_do_not_merge`) and entity-resolution excludes it from merge proposals. Symmetric —
  stored order-independent. Idempotent.
  """
  @spec block_merge(String.t(), String.t(), String.t(), String.t() | nil) :: :ok
  def block_merge(type, k1, k2, reason \\ nil)
      when is_binary(type) and is_binary(k1) and is_binary(k2) do
    {a, b} = if k1 <= k2, do: {k1, k2}, else: {k2, k1}

    Repo.query!(
      "INSERT INTO node_do_not_merge (type, key_a, key_b, reason) VALUES ($1,$2,$3,$4) " <>
        "ON CONFLICT (type, key_a, key_b) DO NOTHING",
      [type, a, b, reason]
    )

    :ok
  end

  @doc "Is this `(type, k1, k2)` pair blocked from merging (S4 do-not-merge)? Order-independent."
  @spec merge_blocked?(String.t(), String.t(), String.t()) :: boolean()
  def merge_blocked?(type, k1, k2) when is_binary(type) and is_binary(k1) and is_binary(k2) do
    {a, b} = if k1 <= k2, do: {k1, k2}, else: {k2, k1}

    %{rows: [[c]]} =
      Repo.query!(
        "SELECT count(*) FROM node_do_not_merge WHERE type = $1 AND key_a = $2 AND key_b = $3",
        [type, a, b]
      )

    c > 0
  end

  @spec node_id(String.t(), String.t()) :: integer() | nil
  defp node_id(type, key) do
    case Repo.query!("SELECT id FROM node WHERE type = $1 AND key = $2", [type, key]) do
      %{rows: [[id]]} -> id
      _ -> nil
    end
  end

  # Ghost-purge (workspace ADR-17 §2 / ADR-13, blackboard gc-ghost-purge). When a
  # SOURCE node is merged/deleted, the evidence DERIVED from it (edges whose
  # `edge_provenance.source_node_id` = that node) must go — else a `has_step`/claim edge
  # lingers with an origin pointing at a dead source and can stitch a phantom step.
  # Council (codex + gemini, unanimous): PURGE not re-point (extraction is a re-derivable
  # derivative of source text; re-attributing to the survivor fabricates provenance and
  # ER duplicates must not corroborate independently). Delete only the alias's provenance
  # rows, then only edges with NO remaining provenance (an edge still attested by another
  # source survives, its distinct-origin seen_count recomputed) — mirroring the
  # enrichment `reconcile`. Runs synchronously inside the merge transaction, before the
  # alias node row is deleted. Deadlock-safe (gemini): lock the affected edge rows
  # `FOR UPDATE ORDER BY id` first — the same ascending-id order the enrichment reconcile
  # uses — so concurrent merge/ingest can never acquire edge locks in a conflicting order.
  # Ghost-purge race guard: if this edge is derived from a source node, pin that node
  # FOR SHARE for the txn and FAIL (rollback) if it is already gone. A concurrent
  # `merge_nodes` locks the source FOR UPDATE, deletes it, then purges its derived
  # edges — without this, a write in flight during that merge could land AFTER the
  # purge and leave a ghost (or an edge whose only provenance the purge already
  # removed). Called BEFORE the edge upsert lock, so the node→edge acquisition order
  # matches merge's and cannot deadlock. No-op for a non-derived edge (nil source).
  @spec guard_source!(integer() | nil) :: :ok
  defp guard_source!(nil), do: :ok

  defp guard_source!(source_node_id) do
    if Repo.query!("SELECT id FROM node WHERE id = $1 FOR SHARE", [source_node_id]).num_rows == 1 do
      :ok
    else
      Repo.rollback({:source_gone, source_node_id})
    end
  end

  @spec purge_source_edges(integer()) :: :ok
  defp purge_source_edges(alias_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT DISTINCT edge_id FROM edge_provenance WHERE source_node_id = $1 ORDER BY edge_id",
        [alias_id]
      )

    edge_ids = Enum.map(rows, fn [id] -> id end)

    if edge_ids != [] do
      # Ordered lock (deadlock-safety); the ids are already ascending from the query.
      Repo.query!("SELECT id FROM edge WHERE id = ANY($1::bigint[]) ORDER BY id FOR UPDATE", [
        edge_ids
      ])

      Repo.query!("DELETE FROM edge_provenance WHERE source_node_id = $1", [alias_id])

      # Edges left with no provenance are orphaned → delete; survivors lost one source,
      # so recompute their distinct-origin seen_count (ADR-13).
      Repo.query!(
        "DELETE FROM edge e WHERE e.id = ANY($1::bigint[]) " <>
          "AND NOT EXISTS (SELECT 1 FROM edge_provenance ep WHERE ep.edge_id = e.id)",
        [edge_ids]
      )

      Repo.query!(
        "UPDATE edge e SET seen_count = " <>
          "(SELECT count(DISTINCT coalesce(lineage, origin, provenance)) FROM edge_provenance ep WHERE ep.edge_id = e.id) " <>
          "WHERE e.id = ANY($1::bigint[])",
        [edge_ids]
      )
    end

    :ok
  end

  # Re-point every edge touching `alias_id` onto `into_id`, merging on natural-key
  # collisions and dropping self-loops. Returns the number of alias edges handled.
  @spec repoint_edges(integer(), integer()) :: non_neg_integer()
  defp repoint_edges(alias_id, into_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT id, src, dst, type, visibility_scope FROM edge WHERE src = $1 OR dst = $1",
        [alias_id]
      )

    Enum.each(rows, fn [eid, src, dst, etype, scope] ->
      new_src = if src == alias_id, do: into_id, else: src
      new_dst = if dst == alias_id, do: into_id, else: dst
      repoint_one(eid, new_src, new_dst, etype, scope)
    end)

    length(rows)
  end

  @spec repoint_one(integer(), integer(), integer(), String.t(), String.t()) :: :ok
  defp repoint_one(eid, new_src, new_dst, _etype, _scope) when new_src == new_dst do
    # Merge collapsed this edge into a self-loop — drop it (CASCADE clears provenance).
    Repo.query!("DELETE FROM edge WHERE id = $1", [eid])
    :ok
  end

  defp repoint_one(eid, new_src, new_dst, etype, scope) do
    validate_repoint_endpoints!(new_src, new_dst, etype)

    case existing_edge(new_src, etype, new_dst, scope) do
      target when is_integer(target) and target != eid ->
        # Natural-key collision: union the alias edge's (provenance, origin) rows
        # into the survivor, recompute its distinct-ORIGIN seen_count (workspace
        # ADR-13 — a merge counts distinct evidential origins, so folding two
        # spellings of one source cannot over-corroborate), then drop the alias edge.
        Repo.query!(
          "INSERT INTO edge_provenance (edge_id, provenance, origin, source_node_id) " <>
            "SELECT $1, provenance, origin, source_node_id FROM edge_provenance WHERE edge_id = $2 " <>
            "ON CONFLICT (edge_id, provenance) DO NOTHING",
          [target, eid]
        )

        Repo.query!(
          "UPDATE edge SET seen_count = (SELECT count(DISTINCT coalesce(lineage, origin, provenance)) FROM edge_provenance WHERE edge_id = $1), last_seen = now(), updated_at = now() WHERE id = $1",
          [target]
        )

        # schema v13: the alias edge's validity intervals are history, not provenance — carry
        # them onto the survivor (CASCADE would silently delete them with the edge).
        Swarm.Graph.Temporal.move_intervals(eid, target)
        Repo.query!("DELETE FROM edge WHERE id = $1", [eid])
        :ok

      _ ->
        # No collision — re-point in place.
        Repo.query!(
          "UPDATE edge SET src = $2, dst = $3, updated_at = now() WHERE id = $1",
          [eid, new_src, new_dst]
        )

        :ok
    end
  end

  @spec validate_repoint_endpoints!(integer(), integer(), String.t()) :: :ok | no_return()
  defp validate_repoint_endpoints!(src, dst, type) do
    {src_endpoint, dst_endpoint} = endpoint_metadata(src, dst)

    case Contract.validate_relation_endpoints(type, src_endpoint, dst_endpoint) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback({:contract, reason})
    end
  end

  @spec validate_rename_endpoints!(integer(), String.t()) :: :ok | no_return()
  defp validate_rename_endpoints!(node_id, new_key) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT e.type,
               src.id, src.scope, src.type, src.key,
               dst.id, dst.scope, dst.type, dst.key
        FROM edge e
        JOIN node src ON src.id = e.src
        JOIN node dst ON dst.id = e.dst
        WHERE e.src = $1 OR e.dst = $1
        FOR SHARE OF e, src, dst
        """,
        [node_id]
      )

    Enum.each(rows, fn [
                         edge_type,
                         src_id,
                         src_scope,
                         src_type,
                         src_key,
                         dst_id,
                         dst_scope,
                         dst_type,
                         dst_key
                       ] ->
      src_endpoint =
        endpoint_with_renamed_key(src_id, src_scope, src_type, src_key, node_id, new_key)

      dst_endpoint =
        endpoint_with_renamed_key(dst_id, dst_scope, dst_type, dst_key, node_id, new_key)

      case Contract.validate_relation_endpoints(edge_type, src_endpoint, dst_endpoint) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback({:contract, reason})
      end
    end)

    :ok
  end

  defp endpoint_with_renamed_key(id, scope, type, key, renamed_id, new_key) do
    %{id: id, scope: scope, type: type, key: if(id == renamed_id, do: new_key, else: key)}
  end

  @spec existing_edge(integer(), String.t(), integer(), String.t()) :: integer() | nil
  defp existing_edge(src, type, dst, scope) do
    case Repo.query!(
           "SELECT id FROM edge WHERE src = $1 AND type = $2 AND dst = $3 AND visibility_scope = $4",
           [src, type, dst, scope]
         ) do
      %{rows: [[id]]} -> id
      _ -> nil
    end
  end

  # Endpoint metadata for the visibility-invariant and governed-relation checks
  # (swarm ADR-4 / structural spine). One indexed read of both endpoints; a
  # missing node yields a nil endpoint → rejected by the scope check. `FOR SHARE`
  # locks the endpoint rows for this transaction so a concurrent re-scope cannot
  # widen an endpoint between this check and the edge insert (closes the
  # read-then-write TOCTOU window; later narrowing is a separate, documented gap).
  @spec endpoint_metadata(integer(), integer()) :: {map() | nil, map() | nil}
  defp endpoint_metadata(src, dst) do
    %{rows: rows} =
      Repo.query!("SELECT id, scope, type, key FROM node WHERE id = ANY($1) FOR SHARE", [
        [src, dst]
      ])

    by_id =
      Map.new(rows, fn [id, scope, type, key] ->
        {id, %{id: id, scope: scope, type: type, key: key}}
      end)

    {Map.get(by_id, src), Map.get(by_id, dst)}
  end

  @spec endpoint_scope(map() | nil) :: String.t() | nil
  defp endpoint_scope(%{scope: scope}), do: scope
  defp endpoint_scope(nil), do: nil

  # Insert the edge identity, or no-op onto the existing row; return its id. The
  # no-op `DO UPDATE` lets us RETURNING the id on conflict without clobbering
  # weight/reliability of an already-reinforced edge.
  @spec upsert_identity(
          integer(),
          integer(),
          String.t(),
          String.t(),
          float(),
          float(),
          String.t(),
          integer() | nil
        ) ::
          integer()
  defp upsert_identity(src, dst, type, scope, weight, reliability, evidence_kind, step_ordinal) do
    # evidence_kind + step_ordinal are set on first insert (like weight/reliability);
    # the no-op DO UPDATE keeps the original on reinforcement.
    sql = """
    INSERT INTO edge (src, dst, type, visibility_scope, weight, reliability, evidence_kind, step_ordinal, seen_count)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 0)
    ON CONFLICT (src, type, dst, visibility_scope)
    DO UPDATE SET last_seen = edge.last_seen
    RETURNING id
    """

    %{rows: [[id]]} =
      Repo.query!(sql, [src, dst, type, scope, weight, reliability, evidence_kind, step_ordinal])

    id
  end

  # Record one (provenance, origin, lineage) event and classify what it did for the edge's
  # distinct-LINEAGE count (workspace ADR-13 + master-plan S1):
  #   :duplicate        — the same emission instance, already recorded (no-op);
  #   :existing_lineage — a new event, but its upstream lineage is already counted (audit only);
  #   :new_lineage      — a new event introducing a lineage the edge had not seen (reinforces).
  @spec record_event(integer(), String.t(), String.t(), String.t() | nil, integer() | nil) ::
          :duplicate | :existing_lineage | :new_lineage
  defp record_event(edge_id, provenance, origin, lineage, source_node_id) do
    sql = """
    INSERT INTO edge_provenance (edge_id, provenance, origin, lineage, source_node_id)
    VALUES ($1, $2, $3, $4, $5)
    ON CONFLICT (edge_id, provenance) DO NOTHING
    RETURNING edge_id
    """

    if Repo.query!(sql, [edge_id, provenance, origin, lineage, source_node_id]).num_rows == 1 do
      # New event recorded. Is this the FIRST row carrying this LINEAGE (this row included)?
      # If so it is a new distinct upstream lineage → reinforces (S1). Three origins from one
      # lineage reinforce only ONCE.
      #
      # Race-safety: this read-then-classify is exact only because the caller's
      # `upsert_identity` already holds the edge row lock for this transaction
      # (its `ON CONFLICT DO UPDATE` locks the conflicting row), serialising
      # concurrent same-edge reinforcements. Do NOT drop that conflict-update or
      # this count can race two same-lineage events into a double reinforcement.
      %{rows: [[c]]} =
        Repo.query!(
          "SELECT count(*) FROM edge_provenance WHERE edge_id = $1 AND coalesce(lineage, origin, provenance) = $2",
          [edge_id, lineage]
        )

      if c == 1, do: :new_lineage, else: :existing_lineage
    else
      :duplicate
    end
  end

  # S1 lineage default = the origin itself (per-source lineage) — behaviorally identical to the
  # pre-S1 distinct-origin count, so this lands the MECHANISM (column + `:lineage` opt + lineage-
  # aware `seen_count` everywhere) with ZERO behavior change. The GRANULARITY POLICY — which
  # origins collapse to one upstream (the wiki family dedups at PAGE level, NOT "all wiki = 1"; a
  # coarse all-wiki collapse wrongly merged two independent pages' attestations, caught by
  # worker_test) — is a designed S1-step-2 (see board). Connectors pass an explicit `:lineage` to
  # opt into coarser grouping once that policy exists.
  @spec lineage_of(String.t() | nil) :: String.t() | nil
  defp lineage_of(origin), do: origin

  # Atomic increment in the engine (ADR-1), not a read-modify-write in app code.
  @spec bump_seen(integer()) :: integer()
  defp bump_seen(edge_id) do
    sql = """
    UPDATE edge
       SET seen_count = seen_count + 1, last_seen = now(), updated_at = now()
     WHERE id = $1
    RETURNING seen_count
    """

    %{rows: [[seen]]} = Repo.query!(sql, [edge_id])
    seen
  end

  @spec current_seen(integer()) :: integer()
  defp current_seen(edge_id) do
    %{rows: [[seen]]} = Repo.query!("SELECT seen_count FROM edge WHERE id = $1", [edge_id])
    seen
  end

  # --- Stigmergy signal (swarm ADR-2) ---------------------------------------
  # Append the transactional outbox row. Called INSIDE the caller's transaction,
  # so the graph change and its signal commit or roll back together. The single
  # tailer consumes these in `seq` order to wake the workers that care.
  @spec emit_outbox(String.t(), String.t(), map(), String.t()) :: :ok
  defp emit_outbox(change, target_key, payload, idem_key) do
    Repo.query!(
      "INSERT INTO outbox (change, target_key, payload, idem_key) VALUES ($1, $2, $3::jsonb, $4)",
      [change, target_key, Jason.encode!(payload), idem_key]
    )

    # Wake hint for the tailer (delivered at COMMIT; correctness still rests on
    # the cursor + poll, so this is best-effort).
    Repo.query!("SELECT pg_notify('stigmergy', '')")
    :ok
  end
end
