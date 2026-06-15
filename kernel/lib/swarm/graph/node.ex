defmodule Swarm.Graph.Node do
  @moduledoc """
  A graph node: user/file/event/concept/task/agent/self/source — everything is a
  node. Carries the day-1 invariant fields: `scope` (ADR-5), `reliability`
  (ADR-3), `vec` + `embed_model` (ADR-6), and the claim/lease columns (ADR-1).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "node" do
    field(:type, :string)
    field(:key, :string)
    field(:vec, Pgvector.Ecto.Vector)
    field(:embed_model, :string)
    field(:scope, :string, default: "private")
    field(:reliability, :float, default: 1.0)
    field(:provenance, :map, default: %{})
    field(:claimed_by, :string)
    field(:lease_until, :utc_datetime_usec)
    field(:fence, :integer, default: 0)

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @castable [:type, :key, :vec, :embed_model, :scope, :reliability, :provenance]

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
  end
end
