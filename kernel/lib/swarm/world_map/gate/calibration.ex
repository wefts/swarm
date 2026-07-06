defmodule Swarm.WorldMap.Gate.Calibration do
  @moduledoc """
  Synthetic calibration for the tier-gate's Stage-2 entail (ADR-17 #2 go/no-go —
  `board/todo/tier-gate-gonogo.md`). The gate SERVES procedures fast (~1.7s vs ~55s consilium),
  but the entail model/prompt sets the **false-serve ↔ needless-escalation** balance: too
  strict vetoes every real procedure, too lenient serves near-misses (a procedure for a
  DIFFERENT task/case). This measures both on a FROZEN, NEUTRAL labelled set (no corpus/intranet
  — leak-free, reproducible) so a config is chosen by numbers, not by overfitting a few queries.

  `false_serve_rate` is the HARD gate (must be ~0): serving a procedure whose task ≠ the query.
  `serve_recall` is the cost being bought down (fraction of genuinely-matching procedures served).
  Mirrors `Swarm.Consilium.Calibration`. Run a config with `score(model: "…", system: "…")`.
  """

  alias Swarm.WorldMap.Coverage.Descriptor
  alias Swarm.WorldMap.Gate

  @typedoc "A labelled gate case: given a procedure (name+steps), SHOULD the gate serve it for the query?"
  @type sample :: %{
          id: String.t(),
          query: String.t(),
          name: String.t(),
          steps: [String.t()],
          serve: boolean()
        }

  # Frozen neutral labels, weighted toward the SHOULD-VETO near-misses (false-serve is the gate).
  @labeled [
    # SHOULD SERVE — the procedure is for the exact task the query asks
    %{
      id: "serve-reset-password",
      query: "how do I reset my account password",
      name: "reset account password",
      steps: ["open the self-service portal", "enter your username", "choose a new password"],
      serve: true
    },
    %{
      id: "serve-add-user-group",
      query: "how do I add a user to a group",
      name: "add a user to a group",
      steps: ["open the admin console", "select the group", "add the user and save"],
      serve: true
    },
    %{
      id: "serve-rotate-cert",
      query: "how do I rotate the TLS certificate",
      name: "rotate the TLS certificate",
      steps: ["generate a new key", "request the certificate", "install it", "reload the service"],
      serve: true
    },
    %{
      id: "serve-connect-vpn",
      query: "how do I connect to the VPN",
      name: "connect to the VPN",
      steps: ["install the client", "import the config", "enter your credentials", "connect"],
      serve: true
    },
    # SHOULD VETO — the procedure is for a DIFFERENT task (opposite / sibling / wrong case)
    %{
      id: "veto-uninstall-vs-install",
      query: "how do I uninstall the agent",
      name: "install the agent",
      steps: ["download the installer", "run setup", "enable the service"],
      serve: false
    },
    %{
      id: "veto-change-username-vs-reset-pw",
      query: "how do I change my username",
      name: "reset account password",
      steps: ["open the self-service portal", "enter your username", "choose a new password"],
      serve: false
    },
    %{
      id: "veto-add-vs-remove-machine",
      query: "how do I add a brand-new machine to the cluster",
      name: "remove a machine from the cluster",
      steps: ["drain the node", "delete it from the cluster", "clean up the records"],
      serve: false
    },
    %{
      id: "veto-restore-vs-backup",
      query: "how do I restore the database from a backup",
      name: "create a database backup",
      steps: ["stop the service", "copy the data directory", "verify the archive"],
      serve: false
    },
    %{
      id: "veto-failover-vs-start",
      query: "how do I configure HA failover for the database",
      name: "start the database",
      steps: ["run the start command", "check the listening port"],
      serve: false
    },
    %{
      id: "veto-rollback-vs-deploy",
      query: "how do I roll back a bad deploy",
      name: "deploy a new release",
      steps: ["tag the release", "push to the registry", "apply the manifest"],
      serve: false
    }
  ]

  @spec labeled() :: [sample()]
  def labeled, do: @labeled

  @typedoc "Gate-calibration metrics; `false_serve_rate` is the go/no-go gate."
  @type report :: %{
          n: non_neg_integer(),
          false_serve_rate: float(),
          serve_recall: float(),
          false_serves: [String.t()],
          missed_serves: [String.t()]
        }

  @doc """
  Score the gate serve/veto decision on the labelled set. `opts`: `:entail_fun` (default builds
  from `:model`/`:system` via `Gate.entail/3`) — so a candidate entail config is measured whole.
  `false_serve_rate` MUST be ~0 to pass; `serve_recall` is the needless-escalation complement.
  """
  @spec score(keyword()) :: report()
  def score(opts \\ []) do
    entail_fun =
      Keyword.get(opts, :entail_fun, fn q, g ->
        Gate.entail(q, g, Keyword.take(opts, [:model, :system]))
      end)

    results =
      Enum.map(@labeled, fn s ->
        {s, served?(build_descriptor(s), entail_fun)}
      end)

    veto_cases = Enum.filter(@labeled, &(&1.serve == false))
    serve_cases = Enum.filter(@labeled, & &1.serve)

    false_serves = for {%{serve: false} = s, true} <- results, do: s.id
    served_correctly = for {%{serve: true} = s, true} <- results, do: s.id

    %{
      n: length(@labeled),
      false_serve_rate: safe_div(length(false_serves), length(veto_cases)),
      serve_recall: safe_div(length(served_correctly), length(serve_cases)),
      false_serves: false_serves,
      missed_serves: Enum.map(serve_cases, & &1.id) -- served_correctly
    }
  end

  defp build_descriptor(%{query: q, name: name, steps: steps}) do
    %Descriptor{
      query: q,
      intent: :procedure,
      procedure_name: name,
      procedure_variants: [
        %{
          citation: "source-1",
          has_generation_collision?: false,
          steps: steps |> Enum.with_index(1) |> Enum.map(fn {k, i} -> %{ordinal: i, key: k} end)
        }
      ],
      blockers: []
    }
  end

  defp served?(descriptor, entail_fun) do
    match?({:serve, _answer, _audit}, Gate.sufficient?(descriptor, entail_fun: entail_fun))
  end

  defp safe_div(_num, 0), do: 0.0
  defp safe_div(num, den), do: num / den
end
