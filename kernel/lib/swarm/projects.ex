defmodule Swarm.Projects do
  @moduledoc """
  The Project registry (workspace ADR-20) — the SOLE data-access container.

  A Project owns Sources; a Source's stable id is the security coordinate of every graph row
  it produced (`scope = "src:" <> source.id`); membership (a user, or a group) in a Project is
  the ONLY way an actor derives a source scope. Human labels (`wiki`, `confluence`) are labels
  and routing hints, never keys — two Confluence connectors in two Projects are two Sources with
  two scopes that cannot collide.

  `effective_scopes/1` is the derivation `Swarm.Identity.scopes_for/1` hands to every gate:

      actor -> user + group memberships -> Project memberships -> Project Sources -> scopes

  plus every Source of a `public` Project for ANY authenticated actor (intentional baseline
  material — never anonymous: `effective_scopes(nil)` is `[]`). Publicness is a Project flag an
  elevated Wheel member flips, never a side effect of membership churn (ADR-20 D5/D6).

  This module is the data layer; the audited, capability-gated callers live in `Swarm.Admin`
  (design: `docs/design/project-access.md` §6).
  """

  alias Swarm.Graph.Contract
  alias Swarm.Identity
  alias Swarm.Repo

  @visibilities ~w(personal shared public)
  @member_roles ~w(owner member)
  # Only the FIXED groups may be Project members (ADR-20 D7) — a legacy/non-fixed group row
  # can never confer visibility (council: codex).
  @fixed_groups ~w(wheel admins staff)

  @type project :: %{
          id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          visibility: String.t(),
          created_by: String.t() | nil,
          created_at: term(),
          updated_at: term()
        }
  @type source :: %{
          id: String.t(),
          project_id: String.t(),
          kind: String.t(),
          label: String.t(),
          origin: String.t(),
          scope: String.t(),
          created_at: term()
        }
  @type member :: %{
          project_id: String.t(),
          user_id: String.t() | nil,
          group_id: String.t() | nil,
          role: String.t(),
          source: String.t(),
          login: String.t() | nil,
          name: String.t() | nil
        }

  @doc "The Project visibility classifications (product words, not a second access system)."
  @spec visibilities() :: [String.t()]
  def visibilities, do: @visibilities

  # ── projects ───────────────────────────────────────────────────────────────

  @doc """
  Create a Project. `attrs`: `:name` (required, non-blank), `:description`, `:visibility`
  (default `shared`), `:created_by` (the creator becomes the Project OWNER member — the data
  owner who may share it further).
  """
  @spec create_project(map()) :: {:ok, project()} | {:error, :invalid_name | :invalid_visibility}
  def create_project(attrs) do
    name = attrs |> Map.get(:name) |> blank_to_nil()
    visibility = Map.get(attrs, :visibility) || "shared"
    created_by = Map.get(attrs, :created_by)

    cond do
      is_nil(name) ->
        {:error, :invalid_name}

      visibility not in @visibilities ->
        {:error, :invalid_visibility}

      true ->
        id = Identity.uuid7()
        insert_project!(id, name, Map.get(attrs, :description), visibility, created_by)
        {:ok, get_project(id)}
    end
  end

  # The project row + the creator's OWNER membership, atomically.
  defp insert_project!(id, name, description, visibility, created_by) do
    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!(
          """
          INSERT INTO project (id, name, description, visibility, created_by)
          VALUES ($1, $2, $3, $4, $5)
          """,
          [dump(id), name, description, visibility, dump_opt(created_by)]
        )

        if created_by do
          Repo.query!(
            """
            INSERT INTO project_membership (project_id, user_id, role, source, granted_by)
            VALUES ($1, $2, 'owner', 'local', $2)
            """,
            [dump(id), dump(created_by)]
          )
        end
      end)

    :ok
  end

  @doc "Fetch a Project by id (a malformed id is `nil`, never a cast error)."
  @spec get_project(String.t()) :: project() | nil
  def get_project(id) do
    with true <- valid_uuid?(id),
         %{rows: [row]} <-
           Repo.query!("SELECT #{project_cols()} FROM project WHERE id = $1", [dump(id)]) do
      to_project(row)
    else
      _ -> nil
    end
  end

  @doc "Every Project, name-ordered (an admin surface)."
  @spec list_projects() :: [project()]
  def list_projects do
    Repo.query!("SELECT #{project_cols()} FROM project ORDER BY name, id").rows
    |> Enum.map(&to_project/1)
  end

  @doc """
  The Projects an actor can see: those they are a member of (directly or via a group) plus
  every `public` Project. `nil` (anonymous) sees none.
  """
  @spec list_projects_for(String.t() | nil) :: [project()]
  def list_projects_for(nil), do: []

  def list_projects_for(user_id) when is_binary(user_id) do
    if valid_uuid?(user_id), do: do_list_projects_for(user_id), else: []
  end

  defp do_list_projects_for(user_id) do
    Repo.query!(
      """
      SELECT #{project_cols("p")}
        FROM project p
       WHERE p.visibility = 'public'
          OR EXISTS (SELECT 1 FROM project_membership pm
                      WHERE pm.project_id = p.id AND pm.user_id = $1)
          OR EXISTS (SELECT 1 FROM project_membership pm
                      JOIN user_group ug ON ug.group_id = pm.group_id
                     WHERE pm.project_id = p.id AND ug.user_id = $1)
       ORDER BY p.name, p.id
      """,
      [dump(user_id)]
    ).rows
    |> Enum.map(&to_project/1)
  end

  @doc "Rename a Project."
  @spec rename_project(String.t(), String.t()) :: :ok | {:error, :not_found | :invalid_name}
  def rename_project(id, name) do
    case blank_to_nil(name) do
      nil -> {:error, :invalid_name}
      n -> update_project(id, "name = $2", [n])
    end
  end

  @doc "Replace a Project's description."
  @spec describe_project(String.t(), String.t() | nil) :: :ok | {:error, :not_found}
  def describe_project(id, description),
    do: update_project(id, "description = $2", [blank_to_nil(description)])

  @doc "Set the visibility classification (`personal` | `shared` | `public`)."
  @spec set_visibility(String.t(), String.t()) ::
          :ok | {:error, :not_found | :invalid_visibility}
  def set_visibility(id, visibility) do
    if visibility in @visibilities,
      do: update_project(id, "visibility = $2", [visibility]),
      else: {:error, :invalid_visibility}
  end

  defp update_project(id, set_clause, params) do
    if valid_uuid?(id) do
      case Repo.query!(
             "UPDATE project SET #{set_clause}, updated_at = now() WHERE id = $1",
             [dump(id) | params]
           ) do
        %{num_rows: 0} -> {:error, :not_found}
        _ -> :ok
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Delete a Project: memberships and Sources cascade. The graph rows written under its Sources
  KEEP their `src:<uuid>` scope — nobody can derive it any more, so they are unreachable
  (fail-closed), not deleted; purging rows is a separate, deliberate operation.
  """
  @spec delete_project(String.t()) :: :ok | {:error, :not_found}
  def delete_project(id) do
    with true <- valid_uuid?(id),
         %{num_rows: 1} <- Repo.query!("DELETE FROM project WHERE id = $1", [dump(id)]) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  # ── sources ────────────────────────────────────────────────────────────────

  @doc """
  Register a Source in a Project and mint its scope. `attrs`: `:kind` (required — a label /
  routing hint such as `wiki` | `confluence` | `ldap` | `iac`), `:label` (defaults to kind),
  `:origin` (`admin` default | `migration`), `:id` (a caller-chosen uuid — fixtures/migration
  parity; normally minted here).
  """
  @spec add_source(String.t(), map()) ::
          {:ok, source()} | {:error, :not_found | :invalid_kind}
  def add_source(project_id, attrs) do
    kind = attrs |> Map.get(:kind) |> blank_to_nil()
    label = attrs |> Map.get(:label) |> blank_to_nil() || kind
    origin = Map.get(attrs, :origin) || "admin"

    cond do
      is_nil(kind) or not Regex.match?(~r/^[a-z][a-z0-9_-]*$/, kind) ->
        {:error, :invalid_kind}

      is_nil(get_project(project_id)) ->
        {:error, :not_found}

      true ->
        id = Map.get(attrs, :id) || Identity.uuid7()

        Repo.query!(
          """
          INSERT INTO source (id, project_id, kind, label, origin)
          VALUES ($1, $2, $3, $4, $5)
          """,
          [dump(id), dump(project_id), kind, label, origin]
        )

        {:ok, get_source(id)}
    end
  end

  @doc "Remove a Source (its rows stay at their now-underivable scope — unreachable)."
  @spec remove_source(String.t()) :: :ok | {:error, :not_found}
  def remove_source(source_id) do
    with true <- valid_uuid?(source_id),
         %{num_rows: 1} <- Repo.query!("DELETE FROM source WHERE id = $1", [dump(source_id)]) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Fetch a Source by id, or `nil`."
  @spec get_source(String.t()) :: source() | nil
  def get_source(source_id) do
    with true <- valid_uuid?(source_id),
         %{rows: [row]} <-
           Repo.query!("SELECT #{source_cols()} FROM source WHERE id = $1", [dump(source_id)]) do
      to_source(row)
    else
      _ -> nil
    end
  end

  @doc "The Sources of a Project, label-ordered."
  @spec sources(String.t()) :: [source()]
  def sources(project_id) do
    if valid_uuid?(project_id) do
      Repo.query!(
        "SELECT #{source_cols()} FROM source WHERE project_id = $1 ORDER BY label, id",
        [dump(project_id)]
      ).rows
      |> Enum.map(&to_source/1)
    else
      []
    end
  end

  @doc """
  The scope a connector must stamp on rows it writes for `source_id` — `src:<uuid>`. Raises
  when the Source is not registered (a connector cannot invent a scope; fail loud, never a
  silent unreadable write).
  """
  @spec scope!(String.t()) :: String.t()
  def scope!(source_id) do
    case get_source(source_id) do
      %{scope: scope} ->
        scope

      nil ->
        raise ArgumentError, "Swarm.Projects.scope!: no registered source #{inspect(source_id)}"
    end
  end

  @doc """
  Operator-loader convenience: the scope of the ONE registered Source of `kind`. Raises when
  none or several exist — ambiguity is resolved by passing a source id, never by guessing.
  Kernel enrichers never call this (they inherit their anchor's scope).
  """
  @spec scope_by_kind!(String.t()) :: String.t()
  def scope_by_kind!(kind) when is_binary(kind) do
    case Repo.query!("SELECT id::text FROM source WHERE kind = $1 ORDER BY created_at", [kind]).rows do
      [[id]] ->
        Contract.source_scope(id)

      [] ->
        raise ArgumentError, "Swarm.Projects.scope_by_kind!: no source of kind #{inspect(kind)}"

      many ->
        raise ArgumentError,
              "Swarm.Projects.scope_by_kind!: #{length(many)} sources of kind #{inspect(kind)} — pass a source id"
    end
  end

  @doc "True iff `scope` is the scope of a registered Source (the ingest boundary check)."
  @spec registered_scope?(term()) :: boolean()
  def registered_scope?(scope) do
    case Contract.scope_source_id(scope) do
      nil -> false
      id -> not is_nil(get_source(id))
    end
  end

  # ── membership ─────────────────────────────────────────────────────────────

  @doc """
  Add a member — `%{user_id: uuid}` or `%{group_id: id}` — to a Project. `opts`: `:role`
  (`member` default | `owner`), `:source` (`local` default), `:granted_by`. Idempotent
  (re-adding updates the role). The group must be one of the kernel's groups.
  """
  @spec add_member(String.t(), map(), keyword()) ::
          :ok | {:error, :not_found | :invalid_member | :unknown_group | :unknown_user}
  def add_member(project_id, member, opts \\ []) do
    role = Keyword.get(opts, :role, "member")
    source = Keyword.get(opts, :source, "local")
    granted_by = Keyword.get(opts, :granted_by)

    cond do
      role not in @member_roles ->
        {:error, :invalid_member}

      # owners are PEOPLE: a group cannot hold the owner role (owner?/2 is user-only)
      role == "owner" and Map.has_key?(member, :group_id) ->
        {:error, :invalid_member}

      is_nil(get_project(project_id)) ->
        {:error, :not_found}

      true ->
        do_add_member(project_id, member, role, source, granted_by)
    end
  end

  defp do_add_member(project_id, %{user_id: user_id}, role, source, granted_by) do
    if valid_uuid?(user_id) and not is_nil(Identity.get_user(user_id)) do
      Repo.query!(
        """
        INSERT INTO project_membership (project_id, user_id, role, source, granted_by)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (project_id, user_id) WHERE user_id IS NOT NULL
        DO UPDATE SET role = EXCLUDED.role
        """,
        [dump(project_id), dump(user_id), role, source, dump_opt(granted_by)]
      )

      :ok
    else
      {:error, :unknown_user}
    end
  end

  defp do_add_member(project_id, %{group_id: group_id}, role, source, granted_by)
       when is_binary(group_id) do
    if group_id in @fixed_groups and Identity.group_exists?(group_id) do
      Repo.query!(
        """
        INSERT INTO project_membership (project_id, group_id, role, source, granted_by)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (project_id, group_id) WHERE group_id IS NOT NULL
        DO UPDATE SET role = EXCLUDED.role
        """,
        [dump(project_id), group_id, role, source, dump_opt(granted_by)]
      )

      :ok
    else
      {:error, :unknown_group}
    end
  end

  defp do_add_member(_project_id, _member, _role, _source, _granted_by),
    do: {:error, :invalid_member}

  @doc "Remove a member (`%{user_id: uuid}` | `%{group_id: id}`) from a Project."
  @spec remove_member(String.t(), map()) :: :ok | {:error, :not_found | :invalid_member}
  def remove_member(project_id, %{user_id: user_id}) do
    if valid_uuid?(project_id) and valid_uuid?(user_id) do
      case Repo.query!(
             "DELETE FROM project_membership WHERE project_id = $1 AND user_id = $2",
             [dump(project_id), dump(user_id)]
           ) do
        %{num_rows: 0} -> {:error, :not_found}
        _ -> :ok
      end
    else
      {:error, :not_found}
    end
  end

  def remove_member(project_id, %{group_id: group_id}) when is_binary(group_id) do
    if valid_uuid?(project_id) do
      case Repo.query!(
             "DELETE FROM project_membership WHERE project_id = $1 AND group_id = $2",
             [dump(project_id), group_id]
           ) do
        %{num_rows: 0} -> {:error, :not_found}
        _ -> :ok
      end
    else
      {:error, :not_found}
    end
  end

  def remove_member(_project_id, _member), do: {:error, :invalid_member}

  @doc "The members of a Project (users with login, groups with name), owners first."
  @spec members(String.t()) :: [member()]
  def members(project_id) do
    if valid_uuid?(project_id) do
      Repo.query!(
        """
        SELECT pm.project_id::text, pm.user_id::text, pm.group_id, pm.role, pm.source,
               u.login, g.name
          FROM project_membership pm
          LEFT JOIN app_user u ON u.id = pm.user_id
          LEFT JOIN access_group g ON g.id = pm.group_id
         WHERE pm.project_id = $1
         ORDER BY (pm.role = 'owner') DESC, pm.group_id NULLS LAST, u.login
        """,
        [dump(project_id)]
      ).rows
      |> Enum.map(fn [pid, uid, gid, role, source, login, name] ->
        %{
          project_id: pid,
          user_id: uid,
          group_id: gid,
          role: role,
          source: source,
          login: login,
          name: name
        }
      end)
    else
      []
    end
  end

  @doc "True iff the user is a member of the Project, directly or through one of their groups."
  @spec member?(String.t(), String.t()) :: boolean()
  def member?(project_id, user_id) do
    valid_uuid?(project_id) and valid_uuid?(user_id) and
      match?(
        %{rows: [[1]]},
        Repo.query!(
          """
          SELECT 1
           WHERE EXISTS (SELECT 1 FROM project_membership pm
                          WHERE pm.project_id = $1 AND pm.user_id = $2)
              OR EXISTS (SELECT 1 FROM project_membership pm
                          JOIN user_group ug ON ug.group_id = pm.group_id
                         WHERE pm.project_id = $1 AND ug.user_id = $2)
          """,
          [dump(project_id), dump(user_id)]
        )
      )
  end

  @doc "True iff the user holds a DIRECT `owner` membership in the Project."
  @spec owner?(String.t(), String.t()) :: boolean()
  def owner?(project_id, user_id) do
    valid_uuid?(project_id) and valid_uuid?(user_id) and
      match?(
        %{rows: [[1]]},
        Repo.query!(
          """
          SELECT 1 FROM project_membership
           WHERE project_id = $1 AND user_id = $2 AND role = 'owner'
          """,
          [dump(project_id), dump(user_id)]
        )
      )
  end

  # ── derivation ─────────────────────────────────────────────────────────────

  @doc """
  The source scopes an actor derives from Project membership (user or group) plus every
  Source of a `public` Project. `nil` — anonymous — derives NOTHING (the literal `public` graph
  scope is the anonymous floor, handled by the caller). Sorted, distinct; never `private`.
  """
  @spec effective_scopes(String.t() | nil) :: [String.t()]
  def effective_scopes(nil), do: []

  def effective_scopes(user_id) when is_binary(user_id) do
    if valid_uuid?(user_id) do
      Repo.query!(
        """
        SELECT DISTINCT 'src:' || s.id::text
          FROM source s
          JOIN project p ON p.id = s.project_id
         WHERE (p.visibility = 'public'
                AND EXISTS (SELECT 1 FROM app_user u WHERE u.id = $1 AND u.status IN ('active', 'invited')))
            OR EXISTS (SELECT 1 FROM project_membership pm
                        WHERE pm.project_id = p.id AND pm.user_id = $1)
            OR EXISTS (SELECT 1 FROM project_membership pm
                        JOIN user_group ug ON ug.group_id = pm.group_id
                       WHERE pm.project_id = p.id AND ug.user_id = $1)
         ORDER BY 1
        """,
        [dump(user_id)]
      ).rows
      |> List.flatten()
    else
      []
    end
  end

  @doc "One Project with its Sources and members, or `nil`."
  @spec project_view(String.t()) ::
          %{project: project(), sources: [source()], members: [member()]} | nil
  def project_view(id) do
    case get_project(id) do
      nil -> nil
      p -> %{project: p, sources: sources(p.id), members: members(p.id)}
    end
  end

  # ── row mapping / helpers ──────────────────────────────────────────────────

  defp project_cols(prefix \\ nil) do
    p = if prefix, do: prefix <> ".", else: ""

    "#{p}id::text, #{p}name, #{p}description, #{p}visibility, #{p}created_by::text, #{p}created_at, #{p}updated_at"
  end

  defp source_cols, do: "id::text, project_id::text, kind, label, origin, created_at"

  defp to_project([id, name, description, visibility, created_by, created_at, updated_at]) do
    %{
      id: id,
      name: name,
      description: description,
      visibility: visibility,
      created_by: created_by,
      created_at: created_at,
      updated_at: updated_at
    }
  end

  defp to_source([id, project_id, kind, label, origin, created_at]) do
    %{
      id: id,
      project_id: project_id,
      kind: kind,
      label: label,
      origin: origin,
      scope: Contract.source_scope(id),
      created_at: created_at
    }
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      t -> t
    end
  end

  defp blank_to_nil(_), do: nil

  defp valid_uuid?(id) when is_binary(id), do: match?({:ok, _}, Ecto.UUID.cast(id))
  defp valid_uuid?(_), do: false

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
  defp dump_opt(nil), do: nil
  defp dump_opt(uuid), do: dump(uuid)
end
