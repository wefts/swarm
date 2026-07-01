defmodule Swarm.Person do
  @moduledoc """
  The person-as-data projection (workspace ADR-16 step 7, data-foundation P5) — the
  bridge from the auth record (`Swarm.Identity`) to the graph, and the first concrete
  "users-as-data" that feeds item 3's world-map.

  A user is projected as a graph `user` node **keyed by their uuid** (the stable link
  — logins change, the uuid does not; the graph node id stays integer). Facts about
  them hang off as claim-edges (`based_in` / `works_on` / `interested_in` / …). Only
  scope-governed knowledge lives here — **never** credentials, password hashes, or the
  IdP subject (those stay in the auth/channel layers).

  ## The leak rule (load-bearing)

  Facts **derived from a user's private chat** must never surface to a scoped corpus
  read. Since the graph carries only a topic `scope` (private < group < public), not an
  owner axis, chat-derived facts are written at **`private`** scope — the narrowest —
  which a corpus reader (public/group scopes) is never granted, so the existing
  scope filter on retrieval/search excludes them. `record_chat_fact/4` enforces this in
  code (the scope is not caller-overridable). Human- or corpus-derived facts may be
  wider and are added through the ordinary graph path.

  ## Orphaned owner (account deletion)

  Deleting an account (`Swarm.Admin.delete_user/2`) calls `anonymize/1`: the person node
  is **re-scoped to private** (detached — no longer discoverable) but kept, and its
  learned facts persist (D11 — self-hosted, not a right-to-erasure). It never dangles.
  """

  alias Swarm.Graph.Store
  alias Swarm.Repo

  @person_type "user"
  # Chat-derived facts are pinned here (not caller-overridable) — the leak rule.
  @chat_scope "private"

  @doc """
  Project (idempotently) the user `uuid` as a graph `user` node and return its integer
  node id. `opts[:scope]` sets the person-as-subject visibility (default `private` —
  undiscoverable until deliberately widened). Never writes credentials/sub.
  """
  @spec project(String.t(), keyword()) :: integer()
  def project(uuid, opts \\ []) when is_binary(uuid) do
    Store.upsert_node(@person_type, uuid, scope: Keyword.get(opts, :scope, "private"))
  end

  @doc "The person node id for `uuid`, or `nil` if not yet projected."
  @spec node_id(String.t()) :: integer() | nil
  def node_id(uuid) do
    case Repo.query!("SELECT id FROM node WHERE type = $1 AND key = $2", [@person_type, uuid]) do
      %{rows: [[id]]} -> id
      %{rows: []} -> nil
    end
  end

  @doc """
  Record a fact learned from `uuid`'s private chat: `(person)-[predicate]->(object)`,
  **forced to private scope** (the leak rule — not caller-overridable) so scoped corpus
  reads can never surface it. Ensures the person + object nodes exist. `evidence_kind`
  is `claim` (LLM-derived, never independent corroboration).
  """
  @spec record_chat_fact(String.t(), String.t(), String.t(), String.t()) :: :ok
  def record_chat_fact(uuid, predicate, object_type, object_key)
      when is_binary(predicate) and is_binary(object_type) and is_binary(object_key) do
    person_id = project(uuid, scope: @chat_scope)
    object_id = Store.upsert_node(object_type, object_key, scope: @chat_scope)
    origin = "chat:" <> uuid

    {:ok, _} =
      Store.add_edge(person_id, object_id, predicate, origin,
        scope: @chat_scope,
        origin: origin,
        evidence_kind: "claim"
      )

    :ok
  end

  @doc """
  Detach an orphaned person node on account deletion: re-scope to `private` (no longer
  discoverable) but keep it and its facts (D11). No-op if the person was never
  projected. Idempotent.
  """
  @spec anonymize(String.t()) :: :ok
  def anonymize(uuid) when is_binary(uuid) do
    Repo.query!(
      "UPDATE node SET scope = 'private', updated_at = now() WHERE type = $1 AND key = $2",
      [@person_type, uuid]
    )

    :ok
  end
end
