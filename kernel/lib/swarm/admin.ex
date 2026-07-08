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

  @type result :: :ok | :not_authorized
  @type scopes_result :: result() | {:error, :ungrantable_scope}

  # ── role grants (superadmin-only) ──────────────────────────────────────

  @doc "Grant a role to a user (superadmin-only). `role` ∈ admin|superadmin."
  @spec grant_role(String.t(), String.t(), String.t()) :: result()
  def grant_role(actor_id, target_id, role) do
    gate_superadmin(actor_id, "grant", target_id, fn ->
      Identity.grant_role(target_id, role, "direct", actor_id)
    end)
  end

  @doc "Revoke a role from a user (superadmin-only)."
  @spec revoke_role(String.t(), String.t(), String.t()) :: result()
  def revoke_role(actor_id, target_id, role) do
    gate_superadmin(actor_id, "revoke", target_id, fn ->
      Identity.revoke_role(target_id, role)
    end)
  end

  # ── manage_access — group membership + scope map ───────────────────────

  @doc "Add a user to a group (`manage_access`)."
  @spec grant_group(String.t(), String.t(), String.t()) :: result()
  def grant_group(actor_id, target_id, group_id) do
    gate_cap(actor_id, "manage_access", "grant", target_id, fn ->
      Identity.add_to_group(target_id, group_id)
    end)
  end

  @doc "Remove a user from a group (`manage_access`)."
  @spec revoke_group(String.t(), String.t(), String.t()) :: result()
  def revoke_group(actor_id, target_id, group_id) do
    gate_cap(actor_id, "manage_access", "revoke", target_id, fn ->
      Identity.remove_from_group(target_id, group_id)
    end)
  end

  @doc """
  Set a group's conferred scopes (`manage_access`). Scopes are validated at the
  grant boundary (person-scope-leak-guard): Contract vocabulary only, `private`
  hard-denied — a rejected grant writes nothing and is audited as denied.
  """
  @spec set_group_scopes(String.t(), String.t(), [String.t()]) :: scopes_result()
  def set_group_scopes(actor_id, group_id, scopes) do
    if "manage_access" in Identity.caps_for(actor_id) do
      case Identity.put_group_scopes(group_id, scopes) do
        :ok ->
          audit(actor_id, "grant", "allowed")
          :ok

        {:error, :ungrantable_scope} = err ->
          audit(actor_id, "grant", "denied")
          err
      end
    else
      audit(actor_id, "grant", "denied")
      :not_authorized
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

  # ── gates ────────────────────────────────────────────────────────────────

  @spec gate_cap(String.t(), String.t(), String.t(), String.t() | nil, (-> any())) :: result()
  defp gate_cap(actor_id, cap, action, target_id, fun) do
    if cap in Identity.caps_for(actor_id) do
      fun.()
      audit(actor_id, action, "allowed", target_user_id: target_id)
      :ok
    else
      audit(actor_id, action, "denied", target_user_id: target_id)
      :not_authorized
    end
  end

  @spec gate_superadmin(String.t(), String.t(), String.t() | nil, (-> any())) :: result()
  defp gate_superadmin(actor_id, action, target_id, fun) do
    if "superadmin" in Identity.roles_for(actor_id) do
      fun.()
      audit(actor_id, action, "allowed", target_user_id: target_id)
      :ok
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
      decision: decision,
      data_returned: false
    })
  end
end
