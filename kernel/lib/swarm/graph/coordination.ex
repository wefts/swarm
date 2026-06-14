defmodule Swarm.Graph.Coordination do
  @moduledoc """
  Fenced claim/lease over task nodes (ADR-1/ADR-2). A claim is an atomic
  compare-and-swap on the node's monotonic `fence`: a writer wins only with a
  strictly greater token, so stale tokens from slow-but-alive holders are
  rejected. Lease renewal is a CAS on the observed `lease_until`.

  Fail-loud: every function returns a typed result the caller must branch on.
  Performance: each operation is a single indexed-row write — O(1) in graph
  size, survives 10× nodes (no scan, no read-modify-write in app code).
  """

  alias Swarm.Repo

  @typedoc "Monotonic fencing token. The caller owns minting (e.g. a sequence)."
  @type token :: integer()

  @default_lease_ms 30_000

  @doc """
  Claim a task node with a fenced CAS. Succeeds only when `token` is strictly
  greater than the stored fence; otherwise the claim is stale (a higher token
  already won).

  `opts`: `:lease_ms` (default #{@default_lease_ms}).
  """
  @spec claim(integer(), String.t(), token(), keyword()) ::
          {:ok, token()} | {:error, :stale}
  def claim(node_id, worker, token, opts \\ [])
      when is_integer(node_id) and is_binary(worker) and is_integer(token) do
    lease_ms = Keyword.get(opts, :lease_ms, @default_lease_ms)

    sql = """
    UPDATE node
       SET claimed_by = $1,
           fence = $2,
           lease_until = now() + ($3 * interval '1 millisecond')
     WHERE id = $4 AND fence < $2
    """

    case Repo.query!(sql, [worker, token, lease_ms, node_id]) do
      %{num_rows: 1} -> {:ok, token}
      %{num_rows: 0} -> {:error, :stale}
    end
  end

  @doc """
  Renew a held lease via CAS on the observed `lease_until`: extends the lease
  only if this worker still holds the node at `fence` and the lease has not been
  rewritten underneath it. Returns `{:error, :lost}` if any guard fails.
  """
  @spec renew_lease(integer(), String.t(), token(), DateTime.t(), keyword()) ::
          {:ok, DateTime.t()} | {:error, :lost}
  def renew_lease(node_id, worker, fence, observed_lease_until, opts \\ [])
      when is_integer(node_id) and is_binary(worker) and is_integer(fence) do
    lease_ms = Keyword.get(opts, :lease_ms, @default_lease_ms)

    sql = """
    UPDATE node
       SET lease_until = now() + ($1 * interval '1 millisecond')
     WHERE id = $2 AND claimed_by = $3 AND fence = $4 AND lease_until = $5
    RETURNING lease_until
    """

    case Repo.query!(sql, [lease_ms, node_id, worker, fence, observed_lease_until]) do
      %{num_rows: 1, rows: [[lease_until]]} -> {:ok, lease_until}
      %{num_rows: 0} -> {:error, :lost}
    end
  end

  @doc "Read current fences for `node_ids`. Missing nodes are absent from the map."
  @spec read_fences([integer()]) :: %{optional(integer()) => integer()}
  def read_fences(node_ids) when is_list(node_ids) do
    %{rows: rows} = Repo.query!("SELECT id, fence FROM node WHERE id = ANY($1)", [node_ids])
    Map.new(rows, fn [id, fence] -> {id, fence} end)
  end
end
