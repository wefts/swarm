defmodule Swarm.Admin do
  @moduledoc """
  Admin-mutable access management + user lifecycle (workspace ADR-16 step 5, D10/D11),
  kernel-owned and **audited**. Every operation takes the **verified** `actor_id` (from
  `Swarm.Actor.resolve/2`), derives the actor's capabilities from the store here (never
  a caller-supplied field), enforces the required capability, and writes an
  `admin_action_audit` row (including denials, for privilege-abuse detection).

  Capability map (ADR-16 D7): `manage_access` (group membership + group→scope map —
  access to *shared* resources), `invite_users`, `manage_users` (deactivate/delete).
  admin holds those three; superadmin holds all + `read_any_conversation`. **Role
  grants are privilege management → superadmin-only** (an admin cannot self-escalate or
  mint admins). An admin can NOT read another user's conversations (that is the
  superadmin break-glass, `Swarm.Conversations.admin_read/3`) nor manage another user's
  own KB.
  """

  alias Swarm.{Audit, Identity}

  # ADR-19: the Superuser group is the only holder of `superadmin`, takes local-only
  # members, and every op on it is superadmin-gated (an admin must not touch it —
  # otherwise an admin could add themselves and self-escalate).
  @superuser_group "superuser"

  @type result :: :ok | :not_authorized
  @type scopes_result :: result() | {:error, :ungrantable_scope}

  # ── role grants — FORBIDDEN per-user (ADR-19) ──────────────────────────

  @doc """
  Per-user role grants are FORBIDDEN (ADR-19: roles attach to GROUPS, never people).
  Always rejected + audited, for everyone including superadmin. A member's role comes
  from the roles their groups confer.
  """
  @spec grant_role(String.t(), String.t(), String.t()) :: {:error, :role_on_user_forbidden}
  def grant_role(actor_id, _target_id, _role) do
    audit(actor_id, "grant_role", "denied", reason: "roles_on_groups_only")
    {:error, :role_on_user_forbidden}
  end

  @doc "Per-user role revokes are FORBIDDEN (ADR-19); roles live on groups."
  @spec revoke_role(String.t(), String.t(), String.t()) :: {:error, :role_on_user_forbidden}
  def revoke_role(actor_id, _target_id, _role) do
    audit(actor_id, "revoke_role", "denied", reason: "roles_on_groups_only")
    {:error, :role_on_user_forbidden}
  end

  # ── manage_access — group membership + scope map ───────────────────────

  @doc """
  Add a user to a group (`manage_access`; the Superuser group is superadmin-only
  and local-members-only, ADR-19).
  """
  @spec grant_group(String.t(), String.t(), String.t()) ::
          result() | {:error, :superuser_local_only}
  def grant_group(actor_id, target_id, group_id) do
    group_gate(actor_id, group_id, "grant", target_id, fn ->
      if group_id == @superuser_group and not Identity.local_only?(target_id),
        do: {:error, :superuser_local_only},
        else: Identity.add_to_group(target_id, group_id)
    end)
  end

  @doc "Remove a user from a group (`manage_access`; Superuser superadmin-only)."
  @spec revoke_group(String.t(), String.t(), String.t()) :: result()
  def revoke_group(actor_id, target_id, group_id) do
    group_gate(actor_id, group_id, "revoke", target_id, fn ->
      Identity.remove_from_group(target_id, group_id)
    end)
  end

  @doc """
  Set a group's conferred scopes (`manage_access`; Superuser superadmin-only).
  Scopes are validated at the grant boundary (person-scope-leak-guard): Contract
  vocabulary only, `private` hard-denied — a rejected grant writes nothing.
  """
  @spec set_group_scopes(String.t(), String.t(), [String.t()]) :: scopes_result()
  def set_group_scopes(actor_id, group_id, scopes) do
    group_gate(actor_id, group_id, "grant", nil, fn ->
      Identity.put_group_scopes(group_id, scopes)
    end)
  end

  # ── manage_access — group lifecycle ─────────────────────────────────────

  @doc "Create a first-class local group (`manage_access`; Superuser superadmin-only)."
  @spec create_group(String.t(), String.t(), String.t() | nil, String.t() | nil) :: result()
  def create_group(actor_id, id, name, desc) do
    group_gate(actor_id, id, "create_group", nil, fn ->
      Identity.create_group(id, name, desc)
    end)
  end

  @doc "Rename a first-class group (`manage_access`; Superuser superadmin-only)."
  @spec rename_group(String.t(), String.t(), String.t() | nil) :: result() | :not_found
  def rename_group(actor_id, id, name) do
    case group_gate(actor_id, id, "rename_group", nil, fn ->
           Identity.rename_group(id, name)
         end) do
      {:error, :not_found} -> :not_found
      other -> other
    end
  end

  @doc """
  Delete a first-class group (`manage_access`; Superuser superadmin-only); non-empty
  groups require confirmation.
  """
  @spec delete_group(String.t(), String.t(), boolean()) :: result() | :not_found | :not_confirmed
  def delete_group(actor_id, id, confirm) do
    if group_authorized?(actor_id, id) do
      cond do
        not Identity.group_exists?(id) ->
          audit(actor_id, "delete_group", "denied")
          :not_found

        Identity.group_member_count(id) > 0 and not confirm ->
          audit(actor_id, "delete_group", "denied", reason: "not_confirmed")
          :not_confirmed

        true ->
          Identity.delete_group(id)
          audit(actor_id, "delete_group", "allowed")
          :ok
      end
    else
      audit(actor_id, "delete_group", "denied")
      :not_authorized
    end
  end

  # ── group role grants (superadmin-only) ─────────────────────────────────

  @doc """
  Set a role conferred by group membership (superadmin-only). `superadmin` is
  bindable ONLY to the Superuser group (ADR-19); any other target is rejected.
  """
  @spec set_group_role(String.t(), String.t(), String.t()) ::
          result() | :not_found | {:error, :invalid_role | :superadmin_superuser_only}
  def set_group_role(actor_id, id, role) do
    if superadmin_binding_ok?(id, role),
      do: do_set_group_role(actor_id, id, role),
      else: deny_superadmin_binding(actor_id)
  end

  # `superadmin` may be bound ONLY to the Superuser group (ADR-19); any other role
  # binds anywhere. Extracted so `set_group_role` stays under the complexity/nesting gates.
  @spec superadmin_binding_ok?(String.t(), String.t()) :: boolean()
  defp superadmin_binding_ok?(id, role), do: role != "superadmin" or id == @superuser_group

  @spec do_set_group_role(String.t(), String.t(), String.t()) ::
          result() | :not_found | {:error, :invalid_role}
  defp do_set_group_role(actor_id, id, role) do
    gate_superadmin(actor_id, "set_group_role", nil, fn ->
      validated_group_role(id, role, fn -> Identity.set_group_role(id, role) end)
    end)
  end

  @spec deny_superadmin_binding(String.t()) :: {:error, :superadmin_superuser_only}
  defp deny_superadmin_binding(actor_id) do
    audit(actor_id, "set_group_role", "denied", reason: "superadmin_superuser_only")
    {:error, :superadmin_superuser_only}
  end

  @doc "Clear a role conferred by group membership (superadmin-only)."
  @spec clear_group_role(String.t(), String.t(), String.t()) ::
          result() | :not_found | {:error, :invalid_role}
  def clear_group_role(actor_id, id, role) do
    gate_superadmin(actor_id, "clear_group_role", nil, fn ->
      validated_group_role(id, role, fn -> Identity.clear_group_role(id, role) end)
    end)
  end

  # Validate a group-role op before applying: bad role → {:error, :invalid_role}; missing group →
  # :not_found; else run `apply_fn`. Extracted so set/clear stay shallow (credo nesting).
  @spec validated_group_role(String.t(), String.t(), (-> any())) ::
          any() | :not_found | {:error, :invalid_role}
  defp validated_group_role(id, role, apply_fn) do
    cond do
      role not in ["admin", "superadmin"] -> {:error, :invalid_role}
      not Identity.group_exists?(id) -> :not_found
      true -> apply_fn.()
    end
  end

  # ── invite_users / manage_users ────────────────────────────────────────

  @doc "Invite a local user (`invite_users`). Returns the created user."
  @spec invite_user(String.t(), map()) :: {:ok, Identity.user()} | :not_authorized
  def invite_user(actor_id, attrs) do
    if "invite_users" in Identity.caps_for(actor_id) do
      {:ok, u} = Identity.invite_user(attrs)
      audit(actor_id, "invite", "allowed", target_user_id: u.id)
      {:ok, u}
    else
      audit(actor_id, "invite", "denied")
      :not_authorized
    end
  end

  @doc "Deactivate an account (`manage_users`) — login dead, learned content stays."
  @spec deactivate_user(String.t(), String.t()) :: result()
  def deactivate_user(actor_id, target_id) do
    gate_cap(actor_id, "manage_users", "deactivate", target_id, fn ->
      Identity.deactivate_user(target_id)
    end)
  end

  @doc "Delete an account (`manage_users`) — every login path removed, content persists."
  @spec delete_user(String.t(), String.t()) :: result()
  def delete_user(actor_id, target_id) do
    gate_cap(actor_id, "manage_users", "delete", target_id, fn ->
      Identity.delete_user(target_id)
      # Detach the person-as-subject projection (ADR-16 step 7) so an orphaned owner
      # never dangles; its learned facts persist (D11).
      Swarm.Person.anonymize(target_id)
    end)
  end

  # ── reads ────────────────────────────────────────────────────────────────

  @doc """
  The user roster for an admin console (admin-cleanup epic). Allowed for ANY of
  the three admin capabilities — the list is prerequisite data for every admin
  workflow (invite needs collision context; deactivate/grants need uuids) —
  council: codex+gemini agreed. A successful read is NOT audited (a roster read
  happens on every admin page load and would drown `admin_action_audit`); a
  DENIED attempt is audited like every other admin op.
  """
  @admin_caps ~w(invite_users manage_users manage_access)
  @spec list_users(String.t(), keyword()) :: {:ok, {[map()], non_neg_integer()}} | :not_authorized
  def list_users(actor_id, opts \\ []) do
    if Enum.any?(@admin_caps, &(&1 in Identity.caps_for(actor_id))) do
      {:ok, Identity.list_users(opts)}
    else
      audit(actor_id, "list_users", "denied")
      :not_authorized
    end
  end

  @doc """
  Read-only group list for the admin console. Same broad admin-cap gate as the
  roster; successful reads are not audited, denied reads are.
  """
  @spec list_groups(String.t()) :: {:ok, [map()]} | :not_authorized
  def list_groups(actor_id) do
    if Enum.any?(@admin_caps, &(&1 in Identity.caps_for(actor_id))) do
      {:ok, Identity.list_groups()}
    else
      audit(actor_id, "list_groups", "denied")
      :not_authorized
    end
  end

  @doc """
  Read-only role list for the admin console. Same broad admin-cap gate as the
  roster; successful reads are not audited, denied reads are.
  """
  @spec list_roles(String.t()) :: {:ok, [map()]} | :not_authorized
  def list_roles(actor_id) do
    if Enum.any?(@admin_caps, &(&1 in Identity.caps_for(actor_id))) do
      {:ok, Identity.list_roles()}
    else
      audit(actor_id, "list_roles", "denied")
      :not_authorized
    end
  end

  @doc """
  Full user detail for the admin console. Same broad admin-cap gate as the
  roster; successful detail reads are not audited, denied reads are.
  """
  @spec get_user(String.t(), String.t()) :: {:ok, map()} | :not_found | :not_authorized
  def get_user(actor_id, target_id) do
    if Enum.any?(@admin_caps, &(&1 in Identity.caps_for(actor_id))) do
      case Identity.get_user_view(target_id) do
        nil -> :not_found
        view -> {:ok, view}
      end
    else
      audit(actor_id, "get_user", "denied")
      :not_authorized
    end
  end

  @doc """
  One group with its members for the admin console detail page. Same broad
  admin-cap gate as the roster; successful reads are not audited, denied reads are.
  """
  @spec get_group(String.t(), String.t()) :: {:ok, map()} | :not_found | :not_authorized
  def get_group(actor_id, group_id) do
    if Enum.any?(@admin_caps, &(&1 in Identity.caps_for(actor_id))) do
      case Identity.get_group(group_id) do
        nil -> :not_found
        view -> {:ok, view}
      end
    else
      audit(actor_id, "get_group", "denied")
      :not_authorized
    end
  end

  # ── manage_access — SSO group mapping ──────────────────────────────────

  @doc """
  List incoming-SSO-group → our-group mappings (`manage_access`). This is
  access-routing config, so it takes the same cap as the mapping mutations
  (not the broad roster gate); a denied read is audited.
  """
  @spec list_sso_map(String.t()) :: {:ok, [map()]} | :not_authorized
  def list_sso_map(actor_id) do
    if "manage_access" in Identity.caps_for(actor_id) do
      {:ok, Identity.list_sso_group_map()}
    else
      audit(actor_id, "list_sso_map", "denied")
      :not_authorized
    end
  end

  @doc """
  Upsert an SSO group mapping (`manage_access`). The target group must already
  exist — an unknown group is `{:error, :unknown_group}` (a caller error), never
  a silently created mapping.
  """
  @spec put_sso_map(String.t(), String.t(), String.t(), String.t()) ::
          result() | {:error, :unknown_group | :sso_superuser_forbidden}
  def put_sso_map(actor_id, provider, incoming, our_group_id) do
    if our_group_id == @superuser_group do
      # ADR-19: Superuser is local-only — an SSO group must never map into it.
      audit(actor_id, "put_sso_map", "denied", reason: "sso_superuser_forbidden")
      {:error, :sso_superuser_forbidden}
    else
      gate_cap(actor_id, "manage_access", "put_sso_map", nil, fn ->
        Identity.put_sso_group_map(provider, incoming, our_group_id)
      end)
    end
  end

  @doc "Delete an SSO group mapping (`manage_access`)."
  @spec delete_sso_map(String.t(), String.t(), String.t()) :: result()
  def delete_sso_map(actor_id, provider, incoming) do
    gate_cap(actor_id, "manage_access", "delete_sso_map", nil, fn ->
      Identity.delete_sso_group_map(provider, incoming)
    end)
  end

  # ── gates ────────────────────────────────────────────────────────────────

  # ADR-19: ops on the Superuser group are superadmin-only (an `admin` must not be able
  # to touch it — else they could add themselves and inherit `superadmin`); every other
  # group is `manage_access`.
  @spec group_gate(String.t(), String.t(), String.t(), String.t() | nil, (-> any())) ::
          result() | {:error, atom()}
  defp group_gate(actor_id, group_id, action, target, fun) do
    if group_id == @superuser_group do
      gate_superadmin(actor_id, action, target, fun)
    else
      gate_cap(actor_id, "manage_access", action, target, fun)
    end
  end

  @spec group_authorized?(String.t(), String.t()) :: boolean()
  defp group_authorized?(actor_id, group_id) do
    if group_id == @superuser_group do
      "superadmin" in Identity.roles_for(actor_id)
    else
      "manage_access" in Identity.caps_for(actor_id)
    end
  end

  @spec gate_cap(String.t(), String.t(), String.t(), String.t() | nil, (-> any())) ::
          result() | {:error, atom()}
  defp gate_cap(actor_id, cap, action, target_id, fun) do
    if cap in Identity.caps_for(actor_id) do
      case fun.() do
        {:error, _reason} = err ->
          audit(actor_id, action, "denied", target_user_id: target_id)
          err

        result ->
          audit(actor_id, action, "allowed", target_user_id: target_id)
          result
      end
    else
      audit(actor_id, action, "denied", target_user_id: target_id)
      :not_authorized
    end
  end

  @spec gate_superadmin(String.t(), String.t(), String.t() | nil, (-> any())) ::
          result() | {:error, atom()}
  defp gate_superadmin(actor_id, action, target_id, fun) do
    if "superadmin" in Identity.roles_for(actor_id) do
      case fun.() do
        {:error, _reason} = err ->
          audit(actor_id, action, "denied", target_user_id: target_id)
          err

        result ->
          audit(actor_id, action, "allowed", target_user_id: target_id)
          result
      end
    else
      audit(actor_id, action, "denied", target_user_id: target_id)
      :not_authorized
    end
  end

  @spec audit(String.t(), String.t(), String.t(), keyword()) :: :ok
  defp audit(actor_id, action, decision, opts \\ []) do
    Audit.record(%{
      actor_id: actor_id,
      action: action,
      target_user_id: Keyword.get(opts, :target_user_id),
      reason: Keyword.get(opts, :reason),
      decision: decision,
      data_returned: false
    })
  end
end
