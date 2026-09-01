defmodule Swarm.Graph.NetworkAddress do
  @moduledoc """
  Deterministic network-address semantics for `net:address:*` / `net:subnet:*`
  nodes.

  Address literals stay in the public graph key for identity, but the same value
  is also stored in PostgreSQL `inet` / `cidr` columns so containment is computed
  by the database instead of string prefixes.
  """

  alias Swarm.Repo

  @type class ::
          :private
          | :cgnat
          | :loopback
          | :link_local
          | :documentation
          | :multicast
          | :ula
          | :public

  @non_public_classes ~w(private cgnat loopback link_local documentation multicast ula)

  @doc "Annotate a network address/subnet node with typed inet/cidr columns."
  @spec annotate_node(integer(), String.t(), String.t()) :: :ok
  def annotate_node(node_id, kind, value) when kind in ["address", "subnet"] do
    Repo.query!(
      """
      UPDATE node
         SET net_addr = swarm_try_inet($2),
             net_range = swarm_try_cidr($2),
             net_address_class = swarm_net_address_class(swarm_try_inet($2)),
             updated_at = now()
       WHERE id = $1
      """,
      [node_id, value]
    )

    :ok
  end

  def annotate_node(_node_id, _kind, _value), do: :ok

  @doc "Return `has_public_address` / `has_private_address` for an address class."
  @spec class_relation(String.t() | nil) :: String.t() | nil
  def class_relation("public"), do: "has_public_address"
  def class_relation(class) when class in @non_public_classes, do: "has_private_address"
  def class_relation(_), do: nil

  @doc "Read a node's deterministic address class."
  @spec node_class(integer()) :: String.t() | nil
  def node_class(node_id) when is_integer(node_id) do
    case Repo.query!("SELECT net_address_class FROM node WHERE id = $1", [node_id]).rows do
      [[class]] -> class
      _ -> nil
    end
  end
end
