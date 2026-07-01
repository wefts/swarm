defmodule Swarm.Audit do
  @moduledoc """
  Append-only admin-action audit trail (workspace ADR-16 D6/D10). Every privileged
  cross-user action records a row here; for break-glass reads the row is written
  **before** any data is returned (`Swarm.Conversations.admin_read/3`). Never updated
  or deleted through this module — it is an immutable log that outlives its subjects
  (no FK), so a deactivated/deleted user's history persists (D11).
  """

  alias Swarm.Repo

  @type entry :: %{
          required(:actor_id) => String.t(),
          required(:action) => String.t(),
          required(:decision) => String.t(),
          required(:data_returned) => boolean(),
          optional(:target_user_id) => String.t() | nil,
          optional(:target_conversation_id) => String.t() | nil,
          optional(:detail) => map() | nil,
          optional(:reason) => String.t() | nil,
          optional(:request_id) => String.t() | nil
        }
  @type row :: %{
          action: String.t(),
          target_user_id: String.t() | nil,
          target_conversation_id: String.t() | nil,
          reason: String.t() | nil,
          decision: String.t(),
          data_returned: boolean(),
          at: term()
        }

  @doc """
  Record one audit entry (a single committed INSERT — so it is durable *before* any
  subsequent data read/return). Returns `:ok`.
  """
  @spec record(entry()) :: :ok
  def record(e) do
    Repo.query!(
      """
      INSERT INTO admin_action_audit
        (actor_id, action, target_user_id, target_conversation_id, detail,
         reason, request_id, decision, data_returned)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
      """,
      [
        dump(e.actor_id),
        e.action,
        dump_opt(Map.get(e, :target_user_id)),
        dump_opt(Map.get(e, :target_conversation_id)),
        Map.get(e, :detail),
        Map.get(e, :reason),
        Map.get(e, :request_id),
        e.decision,
        Map.fetch!(e, :data_returned)
      ]
    )

    :ok
  end

  @doc "Audit rows by `actor_id`, newest first (for the admin UI / tests)."
  @spec for_actor(String.t()) :: [row()]
  def for_actor(actor_id) do
    Repo.query!(
      """
      SELECT action, target_user_id, target_conversation_id, reason, decision, data_returned, at
        FROM admin_action_audit WHERE actor_id = $1 ORDER BY at DESC, id DESC
      """,
      [dump(actor_id)]
    ).rows
    |> Enum.map(fn [action, tu, tc, reason, decision, data_returned, at] ->
      %{
        action: action,
        target_user_id: load_opt(tu),
        target_conversation_id: load_opt(tc),
        reason: reason,
        decision: decision,
        data_returned: data_returned,
        at: at
      }
    end)
  end

  @spec dump(String.t()) :: binary()
  defp dump(uuid), do: Ecto.UUID.dump!(uuid)

  @spec dump_opt(String.t() | nil) :: binary() | nil
  defp dump_opt(nil), do: nil
  defp dump_opt(uuid), do: dump(uuid)

  @spec load_opt(binary() | nil) :: String.t() | nil
  defp load_opt(nil), do: nil
  defp load_opt(bin), do: Ecto.UUID.load!(bin)
end
