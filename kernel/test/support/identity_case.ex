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
    # app_user CASCADE reaches user_email, identity_link, user_group, elevation,
    # project_membership, conversation, message; access_group CASCADE reaches user_group,
    # sso_group_map, project_membership. `admin_action_audit` has NO FK (it outlives its
    # subjects) so the CASCADE doesn't reach it — truncate it explicitly.
    # `project` CASCADE reaches source + project_membership; app_user reaches elevation.
    Swarm.Repo.query!(
      "TRUNCATE app_user, access_group, admin_action_audit, project RESTART IDENTITY CASCADE"
    )

    # The fixed groups (wheel/admins/staff) are seeded by the migration; re-seed after a wipe
    # so provisioning finds the default cohort (ADR-20).
    Swarm.Identity.ensure_fixed_groups()
    :ok
  end

  @doc """
  Register a Project with one Source and return the Source's scope (`src:<uuid>`). `opts`:
  `:name` (project), `:kind`, `:visibility`, `:members` (a list of `%{user_id: _}` |
  `%{group_id: _}` added as members), `:id` (a fixed source uuid — for stable fixtures).
  """
  @spec register_source!(keyword()) :: String.t()
  def register_source!(opts \\ []) do
    {:ok, p} =
      Swarm.Projects.create_project(%{
        name: Keyword.get(opts, :name, "Test project"),
        visibility: Keyword.get(opts, :visibility, "shared")
      })

    {:ok, s} =
      Swarm.Projects.add_source(p.id, %{
        kind: Keyword.get(opts, :kind, "wiki"),
        id: Keyword.get(opts, :id)
      })

    for m <- Keyword.get(opts, :members, []), do: :ok = Swarm.Projects.add_member(p.id, m)
    s.scope
  end
end
