defmodule Swarm.Conversations do
  @moduledoc """
  Kernel-owned conversations, private per owner (workspace ADR-16 step 3 — the
  load-bearing per-user no-leak invariant). User A cannot read user B's
  conversations by any path.

  **One data-access choke point.** Every public function goes through `with_owner/2`,
  which (1) opens a transaction, (2) sets the transaction-local GUC `app.current_user`
  to the *verified* owner uuid (never caller-supplied — the caller resolves it via
  `Swarm.Actor.resolve/2`), and (3) runs the body. Every read/write ALSO carries an
  explicit `owner_id = $owner` predicate in SQL. So ownership is enforced twice:

  - **Primary (always on):** the `WHERE owner_id = $owner` predicate.
  - **Belt (Postgres RLS, FORCE):** the `app.current_user` GUC + row policy, so a
    *future* path that forgets the predicate still cannot escape at the DB. RLS is
    bypassed by a superuser / BYPASSRLS role; the deployed `swarm` role is currently
    superuser, so the belt is dormant until the kernel connects as a non-superuser app
    role (`board/todo/rls-app-role`). The policy is proven under a non-superuser role
    in the test suite.

  Reads never reveal existence: not-owned and not-found both return `:not_found`
  (404-not-403, no existence oracle). Admin break-glass (step 4) reuses this exact
  path, setting the owner to the *target* (impersonation), audited-before-return.

  **Never spawn a `Task`/process that queries these tables from inside `with_owner`**
  (council: gemini) — it checks out a *different* pooled connection with no GUC and
  outside the transaction, so it bypasses the belt (today) / fails closed (once the
  non-superuser role lands). Do the work on the caller's connection.
  """

  alias Swarm.Repo

  @type conversation :: %{
          id: String.t(),
          owner_id: String.t(),
          scope: String.t() | nil,
          title: String.t() | nil,
          created_at: term(),
          updated_at: term()
        }
  @type message :: %{
          id: String.t(),
          role: String.t(),
          body: String.t(),
          author_user_id: String.t() | nil,
          ask_ref: String.t() | nil,
          created_at: term()
        }

  @doc "Create a conversation owned by `owner_id`. `attrs`: `:title`, `:scope`."
  @spec create(String.t(), map()) :: {:ok, conversation()}
  def create(owner_id, attrs) do
    with_owner(owner_id, fn ->
      id = Swarm.Identity.uuid7()

      Repo.query!(
        "INSERT INTO conversation (id, owner_id, scope, title) VALUES ($1, $2, $3, $4)",
        [dump(id), dump(owner_id), Map.get(attrs, :scope), Map.get(attrs, :title)]
      )

      {:ok, fetch_conversation(owner_id, id)}
    end)
  end

  @doc """
  Append a message to a conversation `owner_id` owns. `attrs`: `:role`
  (`"user"`|`"assistant"`), `:body`, `:author_user_id`, `:ask_ref`. `:not_found`
  if the conversation is not owned by `owner_id` (write-side ownership gate).
  """
  @spec add_message(String.t(), String.t(), map()) :: {:ok, message()} | :not_found
  def add_message(_owner_id, conversation_id, _attrs) when not is_binary(conversation_id),
    do: :not_found

  def add_message(owner_id, conversation_id, attrs) do
    if valid_uuid?(conversation_id),
      do: add_message_valid(owner_id, conversation_id, attrs),
      else: :not_found
  end

  defp add_message_valid(owner_id, conversation_id, attrs) do
    with_owner(owner_id, fn ->
      case fetch_conversation(owner_id, conversation_id) do
        nil ->
          :not_found

        _conv ->
          id = Swarm.Identity.uuid7()

          Repo.query!(
            """
            INSERT INTO message (id, conversation_id, author_user_id, role, body, ask_ref)
            VALUES ($1, $2, $3, $4, $5, $6)
            """,
            [
              dump(id),
              dump(conversation_id),
              dump_opt(Map.get(attrs, :author_user_id)),
              Map.fetch!(attrs, :role),
              Map.fetch!(attrs, :body),
              Map.get(attrs, :ask_ref)
            ]
          )

          Repo.query!(
            "UPDATE conversation SET updated_at = now() WHERE id = $1 AND owner_id = $2",
            [dump(conversation_id), dump(owner_id)]
          )

          {:ok, fetch_message(owner_id, id)}
      end
    end)
  end

  @doc "List `owner_id`'s non-deleted conversations, newest first."
  @spec list(String.t()) :: [conversation()]
  def list(owner_id) do
    with_owner(owner_id, fn ->
      Repo.query!(
        """
        SELECT id, owner_id, scope, title, created_at, updated_at
          FROM conversation
         WHERE owner_id = $1 AND deleted_at IS NULL
         ORDER BY updated_at DESC, id DESC
        """,
        [dump(owner_id)]
      ).rows
      |> Enum.map(&to_conversation/1)
    end)
  end

  @doc """
  Fetch a conversation `owner_id` owns, with its messages (chronological).
  `:not_found` for both not-owned and non-existent (no existence oracle).
  """
  @spec get(String.t(), String.t()) ::
          {:ok, %{conversation: conversation(), messages: [message()]}} | :not_found
  def get(_owner_id, conversation_id) when not is_binary(conversation_id), do: :not_found

  def get(owner_id, conversation_id) do
    if valid_uuid?(conversation_id),
      do: get_valid(owner_id, conversation_id),
      else: :not_found
  end

  defp get_valid(owner_id, conversation_id) do
    with_owner(owner_id, fn ->
      case fetch_conversation(owner_id, conversation_id) do
        nil ->
          :not_found

        conv ->
          messages =
            Repo.query!(
              """
              SELECT id, role, body, author_user_id, ask_ref, created_at
                FROM message WHERE conversation_id = $1
               ORDER BY created_at ASC, id ASC
              """,
              [dump(conversation_id)]
            ).rows
            |> Enum.map(&to_message/1)

          {:ok, %{conversation: conv, messages: messages}}
      end
    end)
  end

  @doc "Soft-delete a conversation `owner_id` owns. `:not_found` otherwise."
  @spec soft_delete(String.t(), String.t()) :: :ok | :not_found
  def soft_delete(_owner_id, conversation_id) when not is_binary(conversation_id), do: :not_found

  def soft_delete(owner_id, conversation_id) do
    if valid_uuid?(conversation_id),
      do: soft_delete_valid(owner_id, conversation_id),
      else: :not_found
  end

  defp soft_delete_valid(owner_id, conversation_id) do
    with_owner(owner_id, fn ->
      %{num_rows: n} =
        Repo.query!(
          """
          UPDATE conversation SET deleted_at = now(), updated_at = now()
           WHERE id = $1 AND owner_id = $2 AND deleted_at IS NULL
          """,
          [dump(conversation_id), dump(owner_id)]
        )

      if n == 1, do: :ok, else: :not_found
    end)
  end

  # ── admin break-glass (ADR-16 D6) ─────────────────────────────────────────

  @doc """
  Break-glass read of any user's conversation by a superadmin — NOT an all-rows
  query. Takes the **verified** `actor_id` (from `Swarm.Actor.resolve/2`) and derives
  its capabilities from the store here (never a caller-supplied caps list — council:
  codex). The actor must hold `read_any_conversation`; the read then **impersonates
  the owner** through the normal `get/2` with the *target's* owner id (same predicate
  + RLS GUC), so it sees exactly what the owner sees. An immutable audit row is
  committed **before** the data is returned upward; every outcome is audited.

  Must NOT be called inside an enclosing transaction — otherwise an outer rollback
  could discard the audit after the data was read (council: gemini). Returns the same
  shape as `get/2`, or `:not_authorized` (no cap) / `:not_found`.
  """
  @spec admin_read(String.t(), String.t(), String.t() | nil) ::
          {:ok, %{conversation: conversation(), messages: [message()]}}
          | :not_authorized
          | :not_found
  def admin_read(actor_id, conversation_id, reason) when is_binary(actor_id) do
    if Repo.in_transaction?() do
      raise "Swarm.Conversations.admin_read/3 must not run inside a transaction (audit durability)"
    end

    caps = Swarm.Identity.caps_for(actor_id)
    # Validate the client-supplied id up front; a malformed one is `nil` (audited, no
    # cast-500). Denials still record the *validated* target for forensics (gemini).
    cid = if is_binary(conversation_id) and valid_uuid?(conversation_id), do: conversation_id

    cond do
      "read_any_conversation" not in caps ->
        audit(actor_id, "denied", cid, nil, reason, false)
        :not_authorized

      is_nil(cid) ->
        audit(actor_id, "not_found", nil, nil, reason, false)
        :not_found

      true ->
        case privileged_owner(cid) do
          nil ->
            audit(actor_id, "not_found", cid, nil, reason, false)
            :not_found

          owner ->
            # Read via the owner's own predicate, THEN audit with the actual outcome
            # (accurate data_returned, never a false negative), committed before the
            # result is returned upward (council: codex, gemini).
            result = get(owner, cid)
            audit(actor_id, "allowed", cid, owner, reason, match?({:ok, _}, result))
            result
        end
    end
  end

  # The one legitimately owner-unfiltered read (in this module only — the structural
  # guard forbids it elsewhere): find the conversation's owner so we can impersonate
  # them. NB once the non-superuser app role lands (board/todo/rls-app-role), this
  # must become a SECURITY DEFINER helper to bypass RLS for the owner lookup.
  @spec privileged_owner(String.t()) :: String.t() | nil
  defp privileged_owner(conversation_id) do
    case Repo.query!(
           "SELECT owner_id FROM conversation WHERE id = $1 AND deleted_at IS NULL",
           [dump(conversation_id)]
         ) do
      %{rows: [[owner_id]]} -> load(owner_id)
      %{rows: []} -> nil
    end
  end

  @spec audit(
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          boolean()
        ) ::
          :ok
  defp audit(actor_id, decision, conversation_id, owner_id, reason, data_returned) do
    Swarm.Audit.record(%{
      actor_id: actor_id,
      action: "read_conversation",
      target_conversation_id: conversation_id,
      target_user_id: owner_id,
      reason: reason,
      decision: decision,
      data_returned: data_returned
    })
  end

  # ── the choke point ──────────────────────────────────────────────────────

  # Open a transaction, bind the RLS GUC to the verified owner, run `fun`, then
  # CLEAR the GUC (so if this runs nested inside a broader app transaction, a later
  # raw read in that outer transaction sees '' → NULL → zero rows, not this owner's
  # rows — council: nested-transaction bleed). set_config(..., true) is
  # transaction-local, so it also never leaks across pooled connections. Passes a
  # rollback `{:error, _}` through instead of raising a MatchError (fail closed, not
  # a crash — council: gemini).
  @spec with_owner(String.t(), (-> result)) :: result | {:error, term()} when result: term()
  defp with_owner(owner_id, fun) do
    case Repo.transaction(fn ->
           Repo.query!("SELECT set_config('app.current_user', $1, true)", [owner_id])
           result = fun.()
           Repo.query!("SELECT set_config('app.current_user', '', true)")
           result
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  # Client-supplied ids are validated before use: a malformed uuid is indistinguishable
  # from a non-existent one (`:not_found`), never a cast-error 500 (council: gemini).
  @spec valid_uuid?(String.t()) :: boolean()
  defp valid_uuid?(id), do: match?({:ok, _}, Ecto.UUID.cast(id))

  @spec fetch_conversation(String.t(), String.t()) :: conversation() | nil
  defp fetch_conversation(owner_id, conversation_id) do
    case Repo.query!(
           """
           SELECT id, owner_id, scope, title, created_at, updated_at
             FROM conversation
            WHERE id = $1 AND owner_id = $2 AND deleted_at IS NULL
           """,
           [dump(conversation_id), dump(owner_id)]
         ) do
      %{rows: [row]} -> to_conversation(row)
      %{rows: []} -> nil
    end
  end

  # Owner-scoped by join (discipline: every read carries the owner predicate, even
  # this read-back of a just-inserted id — council: codex).
  @spec fetch_message(String.t(), String.t()) :: message()
  defp fetch_message(owner_id, id) do
    %{rows: [row]} =
      Repo.query!(
        """
        SELECT m.id, m.role, m.body, m.author_user_id, m.ask_ref, m.created_at
          FROM message m
          JOIN conversation c ON c.id = m.conversation_id
         WHERE m.id = $1 AND c.owner_id = $2
        """,
        [dump(id), dump(owner_id)]
      )

    to_message(row)
  end

  # ── row → map ──────────────────────────────────────────────────────────────

  @spec to_conversation([term()]) :: conversation()
  defp to_conversation([id, owner_id, scope, title, created_at, updated_at]) do
    %{
      id: load(id),
      owner_id: load(owner_id),
      scope: scope,
      title: title,
      created_at: created_at,
      updated_at: updated_at
    }
  end

  @spec to_message([term()]) :: message()
  defp to_message([id, role, body, author_user_id, ask_ref, created_at]) do
    %{
      id: load(id),
      role: role,
      body: body,
      author_user_id: load_opt(author_user_id),
      ask_ref: ask_ref,
      created_at: created_at
    }
  end

  # ── uuid helpers ─────────────────────────────────────────────────────────

  @spec dump(String.t()) :: binary()
  defp dump(uuid), do: Ecto.UUID.dump!(uuid)

  @spec dump_opt(String.t() | nil) :: binary() | nil
  defp dump_opt(nil), do: nil
  defp dump_opt(uuid), do: dump(uuid)

  @spec load(binary()) :: String.t()
  defp load(bin), do: Ecto.UUID.load!(bin)

  @spec load_opt(binary() | nil) :: String.t() | nil
  defp load_opt(nil), do: nil
  defp load_opt(bin), do: load(bin)
end
