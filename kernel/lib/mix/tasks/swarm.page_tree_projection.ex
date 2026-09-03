defmodule Mix.Tasks.Swarm.PageTreeProjection do
  @shortdoc "Classify and optionally project CMS page-tree edges"

  @moduledoc """
  Classifies `child_of` rows into page-tree projection buckets and optionally
  writes semantic projections. Writes must target a sandbox clone via
  `SWARM_DB_NAME`; `swarm_staging` is refused for `--apply`.

  Examples:

      mix swarm.page_tree_projection --labels labels.jsonl --out out.jsonl
      SWARM_DB_NAME=swarm_structural_spine_sandbox mix swarm.page_tree_projection --limit 100 --apply
  """

  use Mix.Task

  alias Swarm.Enrichment.PageTreeProjection
  alias Swarm.Repo

  @switches [
    labels: :string,
    out: :string,
    limit: :integer,
    edge_ids: :string,
    apply: :boolean,
    scopes: :string,
    model: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} = OptionParser.parse(args, switches: @switches)
    start_repo!()
    refuse_staging_apply!(opts)

    if Keyword.has_key?(opts, :labels) and Keyword.has_key?(opts, :edge_ids) do
      Mix.raise("--labels and --edge-ids are mutually exclusive")
    end

    rows =
      case Keyword.get(opts, :labels) do
        nil -> db_rows(opts, scopes(opts))
        path -> label_rows(path)
      end

    if rows != [], do: start_ml!()

    out = Keyword.get(opts, :out)
    prepare_output(out)

    results =
      rows
      |> Enum.with_index(1)
      |> Enum.map(fn {row, index} ->
        result = classify_row(row, opts)
        append_output(result, out)
        Mix.shell().info("classified=#{index}/#{length(rows)} bucket=#{result.bucket}")
        result
      end)

    print_summary(results)
  end

  defp start_repo! do
    configure_repo_from_env()
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    case Swarm.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp start_ml! do
    {:ok, _} = Application.ensure_all_started(:grpc)

    case Process.whereis(GRPC.Client.Supervisor) do
      nil ->
        {:ok, _} =
          DynamicSupervisor.start_link(strategy: :one_for_one, name: GRPC.Client.Supervisor)

      _pid ->
        :ok
    end

    if Swarm.Config.ml_pool().enabled do
      case Swarm.ML.ChannelPool.start_link([]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      wait_ml!()
    end
  end

  defp wait_ml!(attempts \\ 20)

  defp wait_ml!(0), do: Mix.raise("ML channel pool did not become healthy")

  defp wait_ml!(attempts) do
    case Swarm.ML.ChannelPool.checkout() do
      {:ok, _channel, _worker} ->
        :ok

      {:error, :unavailable} ->
        Process.sleep(250)
        wait_ml!(attempts - 1)
    end
  end

  defp configure_repo_from_env do
    cfg = Application.get_env(:swarm, Swarm.Repo, [])

    if Keyword.get(cfg, :database) do
      :ok
    else
      database =
        System.get_env("SWARM_DB_NAME") ||
          case System.get_env("SWARM_ENV") do
            nil ->
              Mix.raise("set SWARM_DB_NAME to a sandbox clone, or SWARM_ENV for read-only use")

            "" ->
              Mix.raise("set SWARM_DB_NAME to a sandbox clone, or SWARM_ENV for read-only use")

            env ->
              "swarm_#{env}"
          end

      repo_opts = [
        database: database,
        username: System.get_env("SWARM_DB_USER", "swarm"),
        password: System.get_env("SWARM_DB_PASSWORD", "swarm"),
        hostname: System.get_env("SWARM_DB_HOST", "localhost"),
        port: System.get_env("SWARM_DB_PORT", "5432") |> String.to_integer(),
        pool_size: System.get_env("SWARM_DB_POOL_SIZE", "10") |> String.to_integer()
      ]

      Application.put_env(:swarm, Swarm.Repo, Keyword.merge(cfg, repo_opts))
    end
  end

  defp classify_row(row, opts) do
    decision =
      PageTreeProjection.classify(
        row.child_title,
        row.parent_title,
        row.body || "",
        model: Keyword.get(opts, :model)
      )

    edge_ids =
      if Keyword.get(opts, :apply, false) and Map.has_key?(row, :child_id) do
        PageTreeProjection.write(
          %{id: row.child_id, scope: row.scope},
          decision,
          "page_tree_projection:child_of:#{row.child_of_edge_id}",
          lineage: "wiki:page:#{row.child_id}"
        )
      else
        []
      end

    row
    |> Map.take([
      :id,
      :child_of_edge_id,
      :child_id,
      :child_title,
      :parent_title,
      :label,
      :original_label
    ])
    |> Map.merge(%{bucket: decision.bucket, decision: decision, edge_ids: edge_ids})
  end

  defp db_rows(opts, scopes) do
    case Keyword.get(opts, :edge_ids) do
      nil -> db_rows_by_limit(Keyword.get(opts, :limit, 100), scopes)
      edge_ids -> db_rows_by_edge_ids(parse_ids!(edge_ids), scopes)
    end
  end

  defp db_rows_by_limit(limit, scopes) do
    scope_clause = if scopes == [], do: "", else: "AND child.scope = ANY($2)"
    params = if scopes == [], do: [limit], else: [limit, scopes]

    Repo.query!(
      """
      SELECT e.id, child.id, child.key, child.type, parent.id, parent.key, parent.type,
             child.scope, coalesce(c.body, '')
        FROM edge e
        JOIN node child ON child.id = e.src
        JOIN node parent ON parent.id = e.dst
        LEFT JOIN content c ON c.node_id = child.id
       WHERE e.type = 'child_of'
         #{scope_clause}
       ORDER BY e.id
       LIMIT $1
      """,
      params
    ).rows
    |> Enum.map(fn [
                     edge_id,
                     child_id,
                     child_title,
                     child_type,
                     parent_id,
                     parent_title,
                     parent_type,
                     scope,
                     body
                   ] ->
      db_row(
        edge_id,
        child_id,
        child_title,
        child_type,
        parent_id,
        parent_title,
        parent_type,
        scope,
        body
      )
    end)
  end

  defp db_rows_by_edge_ids(edge_ids, scopes) do
    scope_clause = if scopes == [], do: "", else: "AND child.scope = ANY($2)"
    params = if scopes == [], do: [edge_ids], else: [edge_ids, scopes]

    Repo.query!(
      """
      SELECT e.id, child.id, child.key, child.type, parent.id, parent.key, parent.type,
             child.scope, coalesce(c.body, '')
        FROM edge e
        JOIN node child ON child.id = e.src
        JOIN node parent ON parent.id = e.dst
        LEFT JOIN content c ON c.node_id = child.id
       WHERE e.type = 'child_of'
         AND e.id = ANY($1::bigint[])
         #{scope_clause}
       ORDER BY e.id
      """,
      params
    ).rows
    |> Enum.map(fn [
                     edge_id,
                     child_id,
                     child_title,
                     child_type,
                     parent_id,
                     parent_title,
                     parent_type,
                     scope,
                     body
                   ] ->
      db_row(
        edge_id,
        child_id,
        child_title,
        child_type,
        parent_id,
        parent_title,
        parent_type,
        scope,
        body
      )
    end)
  end

  defp db_row(
         edge_id,
         child_id,
         child_title,
         child_type,
         parent_id,
         parent_title,
         parent_type,
         scope,
         body
       ) do
    %{
      child_of_edge_id: edge_id,
      child_id: child_id,
      child_title: child_title || "",
      child_type: child_type,
      parent_id: parent_id,
      parent_title: parent_title || "",
      parent_type: parent_type,
      scope: scope,
      body: body
    }
  end

  defp parse_ids!(ids) do
    ids
    |> String.split(",", trim: true)
    |> Enum.map(fn id ->
      case Integer.parse(String.trim(id)) do
        {n, ""} when n > 0 -> n
        _ -> Mix.raise("invalid --edge-ids value: #{inspect(id)}")
      end
    end)
  end

  defp label_rows(path) do
    path
    |> File.read!()
    |> decode_rows()
    |> Enum.map(fn m ->
      label = Map.get(m, "label") || Map.get(m, "bucket")

      %{
        id: Map.get(m, "id") || Map.get(m, "edge_id"),
        child_title: title(m, "child_title", "child"),
        parent_title: title(m, "parent_title", "parent"),
        body: Map.get(m, "body") || Map.get(m, "snippet") || Map.get(m, "evidence_snippet") || "",
        label: normalize_label(label),
        original_label: normalize_original_label(label)
      }
    end)
  end

  defp title(row, flat_key, nested_key) do
    case Map.get(row, flat_key) || Map.get(row, nested_key) do
      %{"title" => title} when is_binary(title) -> title
      title when is_binary(title) -> title
      _ -> ""
    end
  end

  defp decode_rows(raw) do
    case Jason.decode(raw) do
      {:ok, rows} when is_list(rows) ->
        rows

      _ ->
        raw
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
    end
  end

  defp normalize_label(nil), do: nil

  defp normalize_label(label) when is_binary(label) do
    case label |> String.downcase() |> String.replace("-", "_") do
      "genuine_containment" -> "part_of"
      "document_about" -> "documents"
      "filing_bucket" -> "filing"
      "uncertain" -> "none"
      bucket -> bucket
    end
  end

  defp normalize_original_label(nil), do: nil

  defp normalize_original_label(label) when is_binary(label),
    do: label |> String.downcase() |> String.replace("-", "_")

  defp prepare_output(nil), do: :ok

  defp prepare_output(path) do
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)
  end

  defp append_output(_result, nil), do: :ok

  defp append_output(result, path),
    do: File.write!(path, Jason.encode!(stringify_bucket(result)) <> "\n", [:append])

  defp stringify_bucket(row), do: Map.update!(row, :bucket, &Atom.to_string/1)

  defp print_summary(results) do
    buckets = Enum.frequencies_by(results, & &1.bucket)
    Mix.shell().info("buckets=" <> inspect(buckets))

    labelled = Enum.filter(results, & &1[:label])

    if labelled != [] do
      uncertain =
        Enum.count(labelled, fn row ->
          row.label == "none" and row[:original_label] == "uncertain"
        end)

      if uncertain > 0 do
        Mix.shell().info("labels.uncertain_mapped_to_none=" <> Integer.to_string(uncertain))
      end

      for bucket <- ~w(documents part_of filing none) do
        predicted = Enum.filter(labelled, &(Atom.to_string(&1.bucket) == bucket))
        actual = Enum.filter(labelled, &(&1.label == bucket))
        correct = Enum.count(predicted, &(&1.label == bucket))
        precision = if predicted == [], do: nil, else: correct / length(predicted)
        recall = if actual == [], do: nil, else: correct / length(actual)

        Mix.shell().info(
          "precision.#{bucket}=" <>
            inspect(precision) <>
            " recall.#{bucket}=" <>
            inspect(recall) <>
            " predicted=" <>
            Integer.to_string(length(predicted)) <>
            " actual=" <> Integer.to_string(length(actual))
        )
      end

      false_part_of =
        labelled
        |> Enum.filter(&(Atom.to_string(&1.bucket) == "part_of" and &1.label != "part_of"))
        |> Enum.map(& &1.id)

      Mix.shell().info(
        "part_of.false_promotions=" <>
          Integer.to_string(length(false_part_of)) <> " ids=" <> inspect(false_part_of)
      )
    end
  end

  defp scopes(opts) do
    opts
    |> Keyword.get(:scopes, "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp refuse_staging_apply!(opts) do
    db = Repo.config()[:database]

    if Keyword.get(opts, :apply, false) and db == "swarm_staging" do
      Mix.raise("refusing --apply against swarm_staging; set SWARM_DB_NAME to a sandbox clone")
    end
  end
end
