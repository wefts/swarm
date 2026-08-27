defmodule Swarm.Admin do
  @moduledoc """
  Admin-mutable access management + user lifecycle + Projects (workspace ADR-16 D10/D11,
  ADR-20 §6), kernel-owned and **audited**. Every operation takes the **verified** actor
  (`Swarm.Identity.actor_ref/0` — a uuid, or `{uuid, sid}` from `Swarm.Actor.resolve/2`),
  derives the actor's capabilities from the store here (never a caller-supplied field),
  enforces the required capability, and writes an `admin_action_audit` row (including
  denials, for privilege-abuse detection).

  Capability boundary (`docs/design/project-access.md` §6):

    * `admin` (conferred by the `admins` group): `manage_access` (fixed-group + Project
      membership), `invite_users`, `manage_users`, `manage_projects`;
    * `superadmin` (ONLY a live, session-bound elevation of a local Wheel member): the above +
      `read_any_conversation` (break-glass), `manage_wheel`, `manage_roles`, `manage_auth`,
      `manage_publicness`.

  Structural closures of self-escalation: an admin cannot touch `wheel` (membership OR any
  lifecycle op on a Wheel member), cannot bind roles, cannot change auth config (SSO map),
  cannot publish (a Project to/from `public`, a Source into a public Project), and cannot mint
  their OWN data visibility (adding themselves, or a group they belong to, to a Project needs
  the Project owner or an elevation). Per-user role grants and group scope grants no longer
  exist and are rejected + audited. The bootstrap invariant — at least one active local Wheel
  member — is enforced here (`{:error, :last_wheel_member}`).
  """

  alias Swarm.{Audit, Elevation, Identity, Projects}

  @wheel "wheel"

  @type actor :: Identity.actor_ref()
  @type result :: :ok | :not_authorized

  # ── per-user role grants / group scope grants — GONE (ADR-19 D2, ADR-20 D3) ──

  @doc "Per-user role grants are FORBIDDEN (roles attach to groups). Always rejected + audited."
  @spec grant_role(actor(), String.t(), String.t()) :: {:error, :role_on_user_forbidden}
  def grant_role(actor, _target_id, _role) do
    audit(actor, "grant_role", "denied", reason: "roles_on_groups_only")
    {:error, :role_on_user_forbidden}
  end

  @doc "Per-user role revokes are FORBIDDEN; roles live on groups."
  @spec revoke_role(actor(), String.t(), String.t()) :: {:error, :role_on_user_forbidden}
  def revoke_role(actor, _target_id, _role) do
    audit(actor, "revoke_role", "denied", reason: "roles_on_groups_only")
    {:error, :role_on_user_forbidden}
  end

  @doc "Groups never grant source visibility (ADR-20 D3). Always rejected + audited."
  @spec set_group_scopes(actor(), String.t(), [String.t()]) :: {:error, :group_scopes_forbidden}
  def set_group_scopes(actor, _group_id, _scopes) do
    audit(actor, "set_group_scopes", "denied", reason: "projects_grant_visibility")
    {:error, :group_scopes_forbidden}
  end

  # ── fixed groups: membership ─────────────────────────────────────────────

  @doc """
  Add a user to a fixed group. `admins` / `staff`: `manage_access`. `wheel`: `manage_wheel`
  (elevation) and local-only members (the Identity belt refuses an SSO-linked user).
  """
  @spec grant_group(actor(), String.t(), String.t()) ::
          result() | {:error, :unknown_group | :wheel_local_only}
  def grant_group(actor, target_id, group_id) do
    gate(actor, group_cap(actor, target_id, group_id), "grant", target_id, fn ->
      Identity.add_to_group(target_id, group_id)
    end)
  end

  @doc """
  Remove a user from a fixed group. `wheel` needs `manage_wheel` and never empties the
  break-glass cohort (`{:error, :last_wheel_member}`).
  """
  @spec revoke_group(actor(), String.t(), String.t()) :: result() | {:error, :last_wheel_member}
  def revoke_group(actor, target_id, group_id) do
    gate(actor, group_cap(actor, target_id, group_id), "revoke", target_id, fn ->
      if group_id == @wheel and last_wheel_member?(target_id),
        do: {:error, :last_wheel_member},
        else: Identity.remove_from_group(target_id, group_id)
    end)
  end

  # `wheel` is elevation-only. So is changing ONE'S OWN membership of any fixed group
  # (council: gemini + tests lens): an admin who could leave `staff`, add `staff` to a Project
  # and rejoin would mint their own visibility in three audited-"allowed" steps.
  defp group_cap(_actor, _target, @wheel), do: "manage_wheel"

  defp group_cap(actor, target_id, _group) do
    if target_id == Identity.actor_uuid(actor), do: "manage_wheel", else: "manage_access"
  end

  # The bootstrap invariant: the op would leave zero active local-only Wheel members.
  defp last_wheel_member?(target_id) do
    Identity.wheel_member?(target_id) and Identity.active_local_wheel_count() <= 1 and
      counts_as_active_local_wheel?(target_id)
  end

  defp counts_as_active_local_wheel?(target_id) do
    match?(%{status: "active"}, Identity.get_user(target_id)) and Identity.local_only?(target_id)
  end

  # ── fixed groups: lifecycle is closed ────────────────────────────────────

  @doc "The group set is fixed (`wheel` / `admins` / `staff`): creation is rejected + audited."
  @spec create_group(actor(), String.t(), String.t() | nil, String.t() | nil) ::
          {:error, :fixed_group_set}
  def create_group(actor, _id, _name, _desc), do: fixed_set(actor, "create_group")

  @doc "The group set is fixed: renaming is rejected + audited."
  @spec rename_group(actor(), String.t(), String.t() | nil) :: {:error, :fixed_group_set}
  def rename_group(actor, _id, _name), do: fixed_set(actor, "rename_group")

  @doc "The group set is fixed: deletion is rejected + audited."
  @spec delete_group(actor(), String.t(), boolean()) :: {:error, :fixed_group_set}
  def delete_group(actor, _id, _confirm), do: fixed_set(actor, "delete_group")

  defp fixed_set(actor, action) do
    audit(actor, action, "denied", reason: "fixed_group_set")
    {:error, :fixed_group_set}
  end

  # ── group role bindings (elevation-only; only `admin` is bindable) ───────

  @doc "Bind the `admin` role to a fixed group (`manage_roles` — elevation)."
  @spec set_group_role(actor(), String.t(), String.t()) ::
          result() | :not_found | {:error, :invalid_role}
  def set_group_role(actor, id, role) do
    gate(actor, "manage_roles", "set_group_role", nil, fn ->
      case Identity.set_group_role(id, role) do
        {:error, :unknown_group} -> :not_found
        other -> other
      end
    end)
  end

  @doc "Clear a group's role binding (`manage_roles` — elevation)."
  @spec clear_group_role(actor(), String.t(), String.t()) ::
          result() | :not_found | {:error, :invalid_role}
  def clear_group_role(actor, id, role) do
    gate(actor, "manage_roles", "clear_group_role", nil, fn ->
      cond do
        role != "admin" -> {:error, :invalid_role}
        not Identity.group_exists?(id) -> :not_found
        true -> Identity.clear_group_role(id, role)
      end
    end)
  end

  # ── invite_users / manage_users ──────────────────────────────────────────

  @doc """
  Invite a local user (`invite_users`). `attrs` may carry `external: true` for a GUEST.
  Returns the created user.
  """
  @spec invite_user(actor(), map()) :: {:ok, Identity.user()} | :not_authorized
  def invite_user(actor, attrs) do
    if "invite_users" in Identity.caps_for(actor) do
      {:ok, u} = Identity.invite_user(attrs)
      audit(actor, "invite", "allowed", target_user_id: u.id)
      {:ok, u}
    else
      audit(actor, "invite", "denied")
      :not_authorized
    end
  end

  @doc """
  Deactivate an account (`manage_users`) — login dead, learned content stays. A WHEEL member
  can only be touched under elevation (`manage_wheel`) and never as the last one.
  """
  @spec deactivate_user(actor(), String.t()) :: result() | {:error, :last_wheel_member}
  def deactivate_user(actor, target_id) do
    gate(actor, user_cap(target_id), "deactivate", target_id, fn ->
      if last_wheel_member?(target_id),
        do: {:error, :last_wheel_member},
        else: Identity.deactivate_user(target_id)
    end)
  end

  @doc """
  Delete an account (`manage_users`) — every login path removed, content persists. Same
  Wheel guard as `deactivate_user/2`.
  """
  @spec delete_user(actor(), String.t()) :: result() | {:error, :last_wheel_member}
  def delete_user(actor, target_id) do
    gate(actor, user_cap(target_id), "delete", target_id, fn ->
      if last_wheel_member?(target_id),
        do: {:error, :last_wheel_member},
        else: delete_user_tx(target_id)
    end)
  end

  # One transaction: the login dies AND the person-as-subject projection (ADR-16 step 7) is
  # re-pinned so an orphaned owner never dangles; its learned facts persist (D11).
  defp delete_user_tx(target_id) do
    {:ok, :ok} =
      Swarm.Repo.transaction(fn ->
        :ok = Identity.delete_user(target_id)
        Swarm.Person.anonymize(target_id)
      end)

    :ok
  end

  # ANY mutation of a Wheel member is a Wheel mutation (council: gemini).
  defp user_cap(target_id) do
    if Identity.wheel_member?(target_id), do: "manage_wheel", else: "manage_users"
  end

  # ── reads ──────────────────────────────────────────────────────────────────

  @admin_caps ~w(invite_users manage_users manage_access manage_projects)

  @doc """
  The user roster for an admin console. Allowed for ANY admin capability — the list is
  prerequisite data for every admin workflow. A successful read is NOT audited (a roster
  read happens on every admin page load and would drown `admin_action_audit`); a DENIED
  attempt is audited like every other admin op.
  """
  @spec list_users(actor(), keyword()) :: {:ok, {[map()], non_neg_integer()}} | :not_authorized
  def list_users(actor, opts \\ []) do
    read(actor, "list_users", fn -> {:ok, Identity.list_users(opts)} end)
  end

  @doc "Read-only group list (any admin cap; denials audited)."
  @spec list_groups(actor()) :: {:ok, [map()]} | :not_authorized
  def list_groups(actor), do: read(actor, "list_groups", fn -> {:ok, Identity.list_groups()} end)

  @doc "Read-only role list (any admin cap; denials audited)."
  @spec list_roles(actor()) :: {:ok, [map()]} | :not_authorized
  def list_roles(actor), do: read(actor, "list_roles", fn -> {:ok, Identity.list_roles()} end)

  @doc "Full user detail (any admin cap; `:not_found` for unknown/tombstoned)."
  @spec get_user(actor(), String.t()) :: {:ok, map()} | :not_found | :not_authorized
  def get_user(actor, target_id) do
    read(actor, "get_user", fn ->
      case Identity.get_user_view(target_id) do
        nil -> :not_found
        view -> {:ok, view}
      end
    end)
  end

  @doc "One group with its members (any admin cap)."
  @spec get_group(actor(), String.t()) :: {:ok, map()} | :not_found | :not_authorized
  def get_group(actor, group_id) do
    read(actor, "get_group", fn ->
      case Identity.get_group(group_id) do
        nil -> :not_found
        view -> {:ok, view}
      end
    end)
  end

  @doc "Incoming-SSO-group → our-group mappings (any admin cap reads; mutation is `manage_auth`)."
  @spec list_sso_map(actor()) :: {:ok, [map()]} | :not_authorized
  def list_sso_map(actor),
    do: read(actor, "list_sso_map", fn -> {:ok, Identity.list_sso_group_map()} end)

  defp read(actor, action, fun) do
    if Enum.any?(@admin_caps, &(&1 in Identity.caps_for(actor))) do
      fun.()
    else
      audit(actor, action, "denied")
      :not_authorized
    end
  end

  # ── auth config: SSO group mapping (elevation-only) ────────────────────────

  @doc """
  Upsert an SSO group mapping (`manage_auth` — elevation). The target must exist and is
  never `wheel` (`{:error, :sso_wheel_forbidden}`).
  """
  @spec put_sso_map(actor(), String.t(), String.t(), String.t()) ::
          result() | {:error, :unknown_group | :sso_wheel_forbidden}
  def put_sso_map(actor, provider, incoming, our_group_id) do
    if our_group_id == @wheel do
      audit(actor, "put_sso_map", "denied", reason: "sso_wheel_forbidden")
      {:error, :sso_wheel_forbidden}
    else
      gate(actor, "manage_auth", "put_sso_map", nil, fn ->
        Identity.put_sso_group_map(provider, incoming, our_group_id)
      end)
    end
  end

  @doc "Delete an SSO group mapping (`manage_auth` — elevation)."
  @spec delete_sso_map(actor(), String.t(), String.t()) :: result()
  def delete_sso_map(actor, provider, incoming) do
    gate(actor, "manage_auth", "delete_sso_map", nil, fn ->
      Identity.delete_sso_group_map(provider, incoming)
    end)
  end

  # ── Projects (the sole data-access container) ──────────────────────────────

  @doc """
  Create a Project (`manage_projects`); the creator becomes its OWNER member. Creating it
  `public` is publishing — `manage_publicness` (elevation).
  """
  @spec create_project(actor(), map()) ::
          {:ok, Projects.project()}
          | :not_authorized
          | {:error, :invalid_name | :invalid_visibility}
  def create_project(actor, attrs) do
    cap =
      if Map.get(attrs, :visibility) == "public", do: "manage_publicness", else: "manage_projects"

    gate(actor, cap, "create_project", nil, fn ->
      Projects.create_project(Map.put(attrs, :created_by, Identity.actor_uuid(actor)))
    end)
  end

  @doc "Rename a Project (`manage_projects`, or the Project owner)."
  @spec rename_project(actor(), String.t(), String.t()) ::
          result() | :not_found | {:error, :invalid_name}
  def rename_project(actor, project_id, name) do
    project_gate(actor, project_id, "manage_projects", "rename_project", fn ->
      Projects.rename_project(project_id, name)
    end)
  end

  @doc "Describe a Project (`manage_projects`, or the Project owner)."
  @spec describe_project(actor(), String.t(), String.t() | nil) :: result() | :not_found
  def describe_project(actor, project_id, description) do
    project_gate(actor, project_id, "manage_projects", "describe_project", fn ->
      Projects.describe_project(project_id, description)
    end)
  end

  @doc """
  Set a Project's visibility. `personal` ⇄ `shared`: `manage_projects` or the owner; any
  change TO or FROM `public`: `manage_publicness` (elevation) — publicness is never an
  ordinary admin act (ADR-20 D6/D11).
  """
  @spec set_project_visibility(actor(), String.t(), String.t()) ::
          result() | :not_found | {:error, :invalid_visibility}
  def set_project_visibility(actor, project_id, visibility) do
    case Projects.get_project(project_id) do
      nil ->
        audit(actor, "set_project_visibility", "denied")
        :not_found

      %{visibility: current} ->
        publicness? = current == "public" or visibility == "public"

        publicness_gate(actor, project_id, publicness?, "set_project_visibility", fn ->
          Projects.set_visibility(project_id, visibility)
        end)
    end
  end

  # A publicness act is elevation-only with NO owner bypass; anything else is the owner's or
  # `manage_projects`.
  defp publicness_gate(actor, _project_id, true, action, fun),
    do: gate(actor, "manage_publicness", action, nil, fun)

  defp publicness_gate(actor, project_id, false, action, fun),
    do: project_gate(actor, project_id, "manage_projects", action, fun)

  @doc """
  Delete a Project (`manage_projects`, or the owner). A Project that still owns Sources needs
  `confirm` (its rows become unreachable, not deleted). A `public` Project needs
  `manage_publicness` (removing baseline material is a publicness change).
  """
  @spec delete_project(actor(), String.t(), boolean()) :: result() | :not_found | :not_confirmed
  def delete_project(actor, project_id, confirm) do
    case Projects.get_project(project_id) do
      nil ->
        audit(actor, "delete_project", "denied")
        :not_found

      %{visibility: vis} ->
        # deleting a PUBLIC Project removes baseline material: a publicness act, elevation-only
        # (no owner bypass); otherwise the owner or `manage_projects`.
        actor
        |> publicness_gate(
          project_id,
          vis == "public",
          "delete_project",
          delete_body(project_id, confirm)
        )
        |> case do
          {:error, :not_confirmed} -> :not_confirmed
          other -> other
        end
    end
  end

  defp delete_body(project_id, confirm) do
    fn ->
      if Projects.sources(project_id) != [] and not confirm,
        do: {:error, :not_confirmed},
        else: Projects.delete_project(project_id)
    end
  end

  @doc """
  Register a Source in a Project (`manage_projects`, or the owner). On a `public` Project the
  Source is published the moment it exists — `manage_publicness` (council: codex).
  """
  @spec add_source(actor(), String.t(), map()) ::
          {:ok, Projects.source()} | :not_authorized | :not_found | {:error, :invalid_kind}
  def add_source(actor, project_id, attrs) do
    case Projects.get_project(project_id) do
      nil ->
        audit(actor, "add_source", "denied")
        :not_found

      %{visibility: "public"} ->
        gate(actor, "manage_publicness", "add_source", nil, fn ->
          Projects.add_source(project_id, attrs)
        end)

      _ ->
        project_gate(actor, project_id, "manage_projects", "add_source", fn ->
          Projects.add_source(project_id, attrs)
        end)
    end
  end

  @doc "Remove a Source (`manage_projects`, or the owner of its Project)."
  @spec remove_source(actor(), String.t()) :: result() | :not_found
  def remove_source(actor, source_id) do
    case Projects.get_source(source_id) do
      nil ->
        audit(actor, "remove_source", "denied")
        :not_found

      %{project_id: pid} ->
        public? = match?(%{visibility: "public"}, Projects.get_project(pid))

        publicness_gate(actor, pid, public?, "remove_source", fn ->
          Projects.remove_source(source_id)
        end)
    end
  end

  @doc """
  Add a member (`%{user_id: _}` | `%{group_id: _}`) to a Project: `manage_access`, or the
  Project owner. **Self-grant guard** (ADR-20 D8 + council codex): when the member IS the
  actor, or is a group the actor belongs to, only the Project owner or an elevated actor may
  add it — an admin never mints their own visibility.
  """
  @spec add_project_member(actor(), String.t(), map(), keyword()) ::
          result()
          | :not_found
          | {:error, :invalid_member | :unknown_group | :unknown_user | :self_grant}
  def add_project_member(actor, project_id, member, opts \\ []) do
    uuid = Identity.actor_uuid(actor)

    cond do
      is_nil(Projects.get_project(project_id)) ->
        audit(actor, "add_project_member", "denied")
        :not_found

      self_grant?(uuid, member) and not may_self_grant?(actor, project_id, uuid) ->
        audit(actor, "add_project_member", "denied",
          target_user_id: Map.get(member, :user_id),
          reason: "self_grant"
        )

        {:error, :self_grant}

      true ->
        project_gate(actor, project_id, "manage_access", "add_project_member", fn ->
          Projects.add_member(project_id, member, Keyword.put(opts, :granted_by, uuid))
        end)
    end
  end

  # Only the Project owner (the data owner sharing their own Project) or an elevated actor may
  # add a member that widens the actor's OWN visibility.
  defp may_self_grant?(actor, project_id, uuid),
    do: Projects.owner?(project_id, uuid) or "superadmin" in Identity.roles_for(actor)

  defp self_grant?(uuid, %{user_id: target}) when is_binary(target), do: target == uuid

  # A group the actor belongs to — and the default cohort ALWAYS (every internal account
  # joins it, so sharing with `staff` is sharing with oneself; council: tests lens).
  defp self_grant?(uuid, %{group_id: g}) when is_binary(g),
    do: g == Identity.default_cohort_group() or g in Identity.groups_for(uuid)

  defp self_grant?(_uuid, _member), do: false

  @doc "Remove a member from a Project (`manage_access`, or the owner)."
  @spec remove_project_member(actor(), String.t(), map()) ::
          result() | :not_found | {:error, :invalid_member}
  def remove_project_member(actor, project_id, member) do
    if Projects.get_project(project_id) == nil do
      audit(actor, "remove_project_member", "denied")
      :not_found
    else
      # an unknown member is `{:error, :not_found}` → `run_audited` maps it to `:not_found`
      project_gate(actor, project_id, "manage_access", "remove_project_member", fn ->
        Projects.remove_member(project_id, member)
      end)
    end
  end

  @doc """
  Projects visible to the actor: with any admin capability, ALL Projects (an admin support
  surface — metadata only); otherwise exactly the Projects the actor is a member of or that
  are `public`. `mine_only: true` restricts an admin to the same.
  """
  @spec list_projects(actor(), keyword()) :: [Projects.project()]
  def list_projects(actor, opts \\ []) do
    uuid = Identity.actor_uuid(actor)

    if not Keyword.get(opts, :mine_only, false) and admin?(actor),
      do: Projects.list_projects(),
      else: Projects.list_projects_for(uuid)
  end

  @doc """
  One Project with Sources + members, for an admin or a member; `:not_found` otherwise
  (404-not-403 — no existence oracle for a non-member).
  """
  @spec get_project(actor(), String.t()) ::
          {:ok,
           %{
             project: Projects.project(),
             sources: [Projects.source()],
             members: [Projects.member()]
           }}
          | :not_found
  def get_project(actor, project_id) do
    uuid = Identity.actor_uuid(actor)

    case Projects.project_view(project_id) do
      nil ->
        :not_found

      %{project: p} = view ->
        cond do
          admin?(actor) or Projects.member?(project_id, uuid) ->
            {:ok, view}

          # a public Project is visible to every authenticated actor — its metadata and
          # Sources, never its member roster (council: tests lens)
          p.visibility == "public" ->
            {:ok, %{view | members: []}}

          true ->
            :not_found
        end
    end
  end

  defp admin?(actor), do: Enum.any?(@admin_caps, &(&1 in Identity.caps_for(actor)))

  # ── gates ──────────────────────────────────────────────────────────────────

  # A Project op is allowed for the capability OR for the Project's owner (the data owner).
  defp project_gate(actor, project_id, cap, action, fun) do
    if Projects.owner?(project_id, Identity.actor_uuid(actor)) do
      run_audited(actor, action, nil, fun)
    else
      gate(actor, cap, action, nil, fun)
    end
  end

  @spec gate(actor(), String.t(), String.t(), String.t() | nil, (-> term())) :: term()
  defp gate(actor, cap, action, target_id, fun) do
    if cap in Identity.caps_for(actor) do
      run_audited(actor, action, target_id, fun)
    else
      audit(actor, action, "denied", target_user_id: target_id)
      :not_authorized
    end
  end

  defp run_audited(actor, action, target_id, fun) do
    case fun.() do
      {:error, :not_found} ->
        audit(actor, action, "denied", target_user_id: target_id, reason: "not_found")
        :not_found

      {:error, reason} = err ->
        audit(actor, action, "denied", target_user_id: target_id, reason: to_string(reason))
        err

      :not_found ->
        audit(actor, action, "denied", target_user_id: target_id, reason: "not_found")
        :not_found

      result ->
        audit(actor, action, "allowed", target_user_id: target_id)
        result
    end
  end

  @spec audit(actor(), String.t(), String.t(), keyword()) :: :ok
  defp audit(actor, action, decision, opts \\ []) do
    Audit.record(%{
      actor_id: Identity.actor_uuid(actor),
      action: action,
      target_user_id: valid_target(Keyword.get(opts, :target_user_id)),
      reason: Keyword.get(opts, :reason),
      decision: decision,
      data_returned: false
    })
  end

  # Forensics keep a validated target uuid; a malformed/absent target audits as nil.
  defp valid_target(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> id
      :error -> nil
    end
  end

  defp valid_target(_), do: nil

  # Reachable for callers that need the elevation state alongside the caps (RPC).
  @doc "The live elevation bound to the actor's session, or `nil`."
  @spec elevation(actor()) :: Elevation.elevation() | nil
  def elevation(actor) do
    {uuid, sid} = Identity.actor_ref(actor)
    Elevation.active(uuid, sid)
  end
end
