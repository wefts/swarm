defmodule Swarm.Graph.Node do
  @moduledoc """
  A graph node: user/file/event/concept/task/agent/self/source — everything is a
  node. Carries the day-1 invariant fields: `scope` (ADR-5), `reliability`
  (ADR-3), `vec` + `embed_model` (ADR-6), and the claim/lease columns (ADR-1).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Swarm.Graph.Contract

  @type t :: %__MODULE__{}

  schema "node" do
    field(:type, :string)
    field(:key, :string)
    field(:vec, Pgvector.Ecto.Vector)
    field(:embed_model, :string)
    field(:scope, :string, default: "private")
    # Zone / tuple-class (T12): `observation` (external evidence) vs `claim`
    # (LLM-generated — never independent corroboration), and lifecycle classes.
    field(:kind, :string, default: "observation")
    field(:reliability, :float, default: 1.0)
    field(:provenance, :map, default: %{})
    field(:claimed_by, :string)
    field(:lease_until, :utc_datetime_usec)
    field(:fence, :integer, default: 0)

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @castable [:type, :key, :vec, :embed_model, :scope, :kind, :reliability, :provenance]

  @doc "Changeset for inserting a node. `type` required; `reliability` in [0,1]."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(node, attrs) do
    node
    |> cast(attrs, @castable)
    |> validate_required([:type, :scope])
    |> validate_number(:reliability,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    # swarm ADR-4: the graph schema is a write-validated contract. Scope is the
    # base vocab OR a well-formed `src:<name>` (ADR-18 lattice) — validated via
    # Contract.valid_scope?/1, the single source of truth (not the finite
    # scopes() list, which excludes the open src:* namespace); type is a
    # non-empty lowercase identifier.
    |> validate_change(:scope, fn :scope, scope ->
      if Contract.valid_scope?(scope), do: [], else: [scope: "is not an admissible scope"]
    end)
    |> validate_inclusion(:kind, Contract.kinds())
    |> validate_format(:type, Contract.type_format())
    # swarm ADR-14 §3.1: node `type` is a closed kernel vocabulary, not merely a
    # well-formed string (edge/relation types stay an open, connector-defined set).
    |> validate_inclusion(:type, Contract.types())
    |> validate_person_scope()
  end

  # The person pin (ADR-16 person-scope-leak-guard, mirrors Contract.validate_node):
  # a `user`-typed node is a person subject, admissible only at `private` scope.
  defp validate_person_scope(changeset) do
    if get_field(changeset, :type) == "user" and get_field(changeset, :scope) != "private" do
      add_error(changeset, :scope, "person nodes are pinned private (no owner axis)")
    else
      changeset
    end
  end
end
