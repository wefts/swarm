defmodule Swarm.Graph.Store do
  @moduledoc """
  Node and edge writes. `add_node` is a validated Ecto insert; `add_edge` is the
  atomic insert-or-increment upsert on the natural key, with the ADR-9
  reinforcement guard (seen_count grows only from provenance-distinct events).

  Performance: both are O(1) in graph size — single indexed-row writes (the
  upsert touches one edge row, one provenance row, one increment), never a scan
  or an app-code read-modify-write. Survives 10× nodes/edges.
  """

  alias Swarm.Graph.Contract
  alias Swarm.Graph.Node
  alias Swarm.Repo

  @typedoc "Result of `add_edge`: the edge id, its current distinct-provenance count, and whether this call reinforced it."
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
    INSERT INTO node (type, key, scope)
    VALUES ($1, $2, $3)
    ON CONFLICT (type, key) DO UPDATE SET updated_at = now()
    RETURNING id
    """

    %{rows: [[id]]} = Repo.query!(sql, [type, canonical, scope])
    id
  end

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

  Reinforcement (ADR-9): `seen_count` increments only when `provenance` is a
  new, distinct event for this edge — re-detecting the same event is a no-op for
  the count. `provenance` is a caller-owned key for the originating ingest event.

  `opts`: `:scope` (default `"private"`), `:weight`, `:reliability`.
  """
  @spec add_edge(integer(), integer(), String.t(), String.t(), keyword()) ::
          {:ok, edge_result()} | {:error, term()}
  def add_edge(src, dst, type, provenance, opts \\ [])
      when is_integer(src) and is_integer(dst) and is_binary(type) and is_binary(provenance) do
    scope = Keyword.get(opts, :scope, "private")
    weight = Keyword.get(opts, :weight, 1.0)
    reliability = Keyword.get(opts, :reliability, 1.0)

    Repo.transaction(fn ->
      # swarm ADR-4: enforce the contract at the write boundary — type/scope
      # vocabulary, reliability range, and the ADR-5 visibility invariant (edge
      # scope no wider than the narrowest endpoint). Reject fail-loud; do NOT
      # silently store a leaking or malformed edge.
      {src_scope, dst_scope} = endpoint_scopes(src, dst)

      case Contract.validate_edge(src_scope, dst_scope, type, scope, reliability, provenance) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback({:contract, reason})
      end

      edge_id = upsert_identity(src, dst, type, scope, weight, reliability)

      if record_provenance(edge_id, provenance) do
        seen = bump_seen(edge_id)

        emit_outbox(
          "edge_reinforced",
          "edge:#{edge_id}",
          %{id: edge_id, src: src, dst: dst, type: type, seen_count: seen},
          "edge:#{edge_id}:#{provenance}"
        )

        %{id: edge_id, seen_count: seen, reinforced: true}
      else
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

        is_nil(into_id) ->
          # Canonical not yet present: rename the alias to the canonical key. Safe —
          # (type, into_key) is free, and the unique index would reject any race.
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
          union_chunks(alias_id, into_id)
          survive_content(alias_id, into_id)
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

  @spec node_id(String.t(), String.t()) :: integer() | nil
  defp node_id(type, key) do
    case Repo.query!("SELECT id FROM node WHERE type = $1 AND key = $2", [type, key]) do
      %{rows: [[id]]} -> id
      _ -> nil
    end
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
    case existing_edge(new_src, etype, new_dst, scope) do
      target when is_integer(target) and target != eid ->
        # Natural-key collision: union the alias edge's provenance into the survivor,
        # recompute its distinct-provenance seen_count, then drop the alias edge.
        Repo.query!(
          "INSERT INTO edge_provenance (edge_id, provenance) " <>
            "SELECT $1, provenance FROM edge_provenance WHERE edge_id = $2 " <>
            "ON CONFLICT (edge_id, provenance) DO NOTHING",
          [target, eid]
        )

        Repo.query!(
          "UPDATE edge SET seen_count = (SELECT count(*) FROM edge_provenance WHERE edge_id = $1), last_seen = now(), updated_at = now() WHERE id = $1",
          [target]
        )

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

  # Endpoint scopes for the visibility-invariant check (swarm ADR-4). One indexed
  # read of both endpoints; a missing node yields a nil scope → rejected. `FOR
  # SHARE` locks the endpoint rows for this transaction so a concurrent re-scope
  # cannot widen an endpoint between this check and the edge insert (closes the
  # read-then-write TOCTOU window; later narrowing is a separate, documented gap).
  @spec endpoint_scopes(integer(), integer()) :: {String.t() | nil, String.t() | nil}
  defp endpoint_scopes(src, dst) do
    %{rows: rows} =
      Repo.query!("SELECT id, scope FROM node WHERE id = ANY($1) FOR SHARE", [[src, dst]])

    by_id = Map.new(rows, fn [id, scope] -> {id, scope} end)
    {Map.get(by_id, src), Map.get(by_id, dst)}
  end

  # Insert the edge identity, or no-op onto the existing row; return its id. The
  # no-op `DO UPDATE` lets us RETURNING the id on conflict without clobbering
  # weight/reliability of an already-reinforced edge.
  @spec upsert_identity(integer(), integer(), String.t(), String.t(), float(), float()) ::
          integer()
  defp upsert_identity(src, dst, type, scope, weight, reliability) do
    sql = """
    INSERT INTO edge (src, dst, type, visibility_scope, weight, reliability, seen_count)
    VALUES ($1, $2, $3, $4, $5, $6, 0)
    ON CONFLICT (src, type, dst, visibility_scope)
    DO UPDATE SET last_seen = edge.last_seen
    RETURNING id
    """

    %{rows: [[id]]} = Repo.query!(sql, [src, dst, type, scope, weight, reliability])
    id
  end

  # Record one provenance event; true iff it was new (distinct) for this edge.
  @spec record_provenance(integer(), String.t()) :: boolean()
  defp record_provenance(edge_id, provenance) do
    sql = """
    INSERT INTO edge_provenance (edge_id, provenance)
    VALUES ($1, $2)
    ON CONFLICT (edge_id, provenance) DO NOTHING
    RETURNING edge_id
    """

    Repo.query!(sql, [edge_id, provenance]).num_rows == 1
  end

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
