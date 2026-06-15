defmodule Swarm.Graph.SchemaMeta do
  @moduledoc """
  Embedding-namespace stamps (ADR-6). One row per namespace records which model
  produced its vectors and the dimensionality. `status` stays `"pending"` until a
  full (re-)embed run is proven to cover the whole corpus — that completion logic
  is later; this module only writes the stamp.

  Performance: a single upsert keyed on the `namespace` primary key — O(1).
  """

  alias Swarm.Repo

  @doc """
  Upsert the stamp for `namespace` (idempotent). On first embed this inserts the
  row as `pending`; later calls refresh `model`/`dim`. `:model` defaults to the
  namespace (the namespace IS the model name for embeddings).
  """
  @spec stamp(String.t(), pos_integer(), keyword()) :: :ok
  def stamp(namespace, dim, opts \\ [])
      when is_binary(namespace) and is_integer(dim) and dim > 0 do
    model = Keyword.get(opts, :model, namespace)

    sql = """
    INSERT INTO schema_meta (namespace, model, dim, status, inserted_at, updated_at)
    VALUES ($1, $2, $3, 'pending', now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC')
    ON CONFLICT (namespace)
    DO UPDATE SET model = EXCLUDED.model, dim = EXCLUDED.dim, updated_at = now() AT TIME ZONE 'UTC'
    """

    Repo.query!(sql, [namespace, model, dim])
    :ok
  end
end
