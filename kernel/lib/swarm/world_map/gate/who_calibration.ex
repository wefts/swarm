defmodule Swarm.WorldMap.Gate.WhoCalibration do
  @moduledoc """
  Synthetic calibration for the tier-gate's `:who` serve path (world-map master-plan E1). Mirrors
  `Swarm.WorldMap.Gate.NetworkCalibration`. The who path serves org-directory neighborhoods fast
  instead of escalating — but the Stage-2 entail must VETO the false-serve class: a DIFFERENT
  person/team than asked, a DIFFERENT relation, or a fact the grounding simply lacks. Frozen,
  neutral, **leak-free** labels — SYNTHETIC names ("Jane Doe", "Platform"), never real employees —
  so a config is chosen by numbers, and nothing intranet enters a committed file.

  `false_serve_rate` is the HARD gate (~0). `serve_recall` is the needless-escalation complement.
  """

  alias Swarm.WorldMap.Coverage.Descriptor
  alias Swarm.WorldMap.Gate

  @typedoc "A labelled who case: given a subject + its facts, SHOULD the gate serve for the query?"
  @type sample :: %{
          id: String.t(),
          query: String.t(),
          subject: String.t(),
          facts: [{String.t(), String.t()}],
          serve: boolean()
        }

  @labeled [
    # SHOULD SERVE — facts state the SPECIFIC relation asked about the SAME person/team
    %{
      id: "serve-team-members",
      query: "who is in the platform team",
      subject: "platform",
      facts: [{"works_in", "Jane Doe"}, {"works_in", "Bob Smith"}],
      serve: true
    },
    %{
      id: "serve-manager-of-person",
      query: "who manages Jane Doe",
      subject: "Jane Doe",
      facts: [{"managed_by", "Carol Lead"}],
      serve: true
    },
    %{
      id: "serve-person-title",
      query: "what is Bob Smith's title",
      subject: "Bob Smith",
      facts: [{"has_title", "Senior Engineer"}],
      serve: true
    },
    %{
      id: "serve-person-location",
      query: "where is Jane Doe based",
      subject: "Jane Doe",
      facts: [{"located_at", "Paris"}],
      serve: true
    },
    # SHOULD VETO — wrong relation / wrong person / a fact the grounding LACKS
    %{
      id: "veto-title-vs-manager",
      query: "who manages Bob Smith",
      subject: "Bob Smith",
      facts: [{"has_title", "Senior Engineer"}, {"works_in", "Platform"}],
      serve: false
    },
    %{
      id: "veto-location-vs-title",
      query: "what is Jane Doe's title",
      subject: "Jane Doe",
      facts: [{"located_at", "Paris"}, {"managed_by", "Carol Lead"}],
      serve: false
    },
    %{
      id: "veto-wrong-person",
      query: "who manages Jane Doe",
      subject: "Bob Smith",
      facts: [{"managed_by", "Dan Other"}],
      serve: false
    },
    %{
      id: "veto-unanswerable-salary",
      query: "what is Jane Doe's salary",
      subject: "Jane Doe",
      facts: [{"has_title", "Senior Engineer"}, {"located_at", "Paris"}],
      serve: false
    }
  ]

  @spec labeled() :: [sample()]
  def labeled, do: @labeled

  @type report :: %{
          n: non_neg_integer(),
          false_serve_rate: float(),
          serve_recall: float(),
          false_serves: [String.t()],
          missed_serves: [String.t()]
        }

  @doc """
  Score the who serve/veto decision on the labelled set. `opts`: `:entail_fun` (default builds from
  `:model` via `Gate.entail/3` with the who entail system). `false_serve_rate` MUST be ~0.
  """
  @spec score(keyword()) :: report()
  def score(opts \\ []) do
    entail_fun = Keyword.get(opts, :entail_fun, &default_who_entail(&1, &2, opts))

    results = Enum.map(@labeled, fn s -> {s, served?(build_descriptor(s), entail_fun)} end)

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

  defp default_who_entail(q, g, opts) do
    entail_opts =
      opts
      |> Keyword.take([:model, :system])
      |> Keyword.put_new(:system, Swarm.WorldMap.Domain.who().entail_system)

    Gate.entail(q, g, entail_opts)
  end

  defp build_descriptor(%{query: q, subject: subject, facts: facts}) do
    %Descriptor{
      query: q,
      intent: :neighborhood,
      domain: :who,
      neighborhood_subject: subject,
      neighborhood_facts:
        Enum.map(facts, fn {rel, obj} ->
          %{relation: rel, object: obj, object_kind: "person", corroboration: 1}
        end),
      blockers: []
    }
  end

  defp served?(descriptor, entail_fun) do
    match?({:serve, _a, _audit}, Gate.sufficient?(descriptor, entail_fun: entail_fun))
  end

  defp safe_div(_num, 0), do: 0.0
  defp safe_div(num, den), do: num / den
end
