defmodule Swarm.Graph.Store do
  @moduledoc """
  Node and edge writes. `add_node` is a validated Ecto insert; `add_edge` is the
  atomic insert-or-increment upsert on the natural key, with the ADR-9
  reinforcement guard (seen_count grows only from provenance-distinct events).

  Performance: both are O(1) in graph size — single indexed-row writes (the
  upsert touches one edge row, one provenance row, one increment), never a scan
  or an app-code read-modify-write. Survives 10× nodes/edges.
  """

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
  """
  @spec upsert_node(String.t(), String.t(), keyword()) :: integer()
  def upsert_node(type, key, opts \\ []) when is_binary(type) and is_binary(key) do
    scope = Keyword.get(opts, :scope, "private")

    sql = """
    INSERT INTO node (type, key, scope)
    VALUES ($1, $2, $3)
    ON CONFLICT (type, key) DO UPDATE SET updated_at = now()
    RETURNING id
    """

    %{rows: [[id]]} = Repo.query!(sql, [type, key, scope])
    id
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
