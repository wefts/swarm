defmodule Swarm.IdentityCase do
  @moduledoc """
  Case template for identity/authz data-layer tests (workspace ADR-16).

  Like `Swarm.GraphCase`: no SQL sandbox (RLS + connection-pool-reuse tests need
  real Postgres connections, not a single sandboxed one), so each test truncates
  the identity tables first and runs `async: false` against the shared schema.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Swarm.{Identity, Repo}

      import Swarm.IdentityCase
    end
  end

  setup do
    truncate_identity()
    :ok
  end

  @doc "Wipe the identity tables (CASCADE reaches the child + join tables)."
  @spec truncate_identity() :: :ok
  def truncate_identity do
    # app_user CASCADE reaches user_email, identity_link, user_group, role_grant;
    # access_group CASCADE reaches user_group, group_scope_map. Both roots listed.
    Swarm.Repo.query!("TRUNCATE app_user, access_group RESTART IDENTITY CASCADE")

    :ok
  end
end
