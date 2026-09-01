defmodule Swarm.WorldMap.Gate.EntityCalibration do
  @moduledoc """
  Synthetic calibration for the tier-gate's `:entity_profile` serve path (H1). Mirrors
  `Swarm.WorldMap.Gate.NetworkCalibration` / `WhoCalibration`: the entity-profile path serves
  claim groups fast instead of escalating, but Stage-2 entail must VETO the false-serve class
  that originally kept entity serving off by default: WRONG entity, WRONG relation, or a
  grounding that only contains loosely related facts. Frozen, neutral, **leak-free** labels only.

  `false_serve_rate` is the HARD gate (~0). `serve_recall` is the needless-escalation complement.
  """

  alias Swarm.WorldMap.Coverage.Descriptor
  alias Swarm.WorldMap.Gate

  @typedoc """
  A labelled entity-profile case: given subject/predicate/object claim groups, SHOULD the gate
  serve for the query?
  """
  @type sample :: %{
          id: String.t(),
          query: String.t(),
          groups: [{String.t(), String.t(), [String.t()]}],
          serve: boolean()
        }

  @labeled [
    # SHOULD SERVE - grounding states the SPECIFIC asked fact about the SAME entity.
    %{
      id: "serve-what-is-service",
      query: "what is Atlas Search",
      groups: [
        {"Atlas Search", "is_a", ["document indexing service"]},
        {"Atlas Search", "owned_by", ["Search Platform"]}
      ],
      serve: true
    },
    %{
      id: "serve-owner",
      query: "who owns the Beacon API",
      groups: [
        {"Beacon API", "owned_by", ["Integration Tools"]},
        {"Beacon API", "has_url", ["https://beacon.example.test"]}
      ],
      serve: true
    },
    %{
      id: "serve-url",
      query: "what is the URL for the Quill dashboard",
      groups: [
        {"Quill dashboard", "has_url", ["https://quill.example.test"]},
        {"Quill dashboard", "is_a", ["editing metrics dashboard"]}
      ],
      serve: true
    },
    %{
      id: "serve-ip",
      query: "what IP does the Marble endpoint use",
      groups: [
        {"Marble endpoint", "has_ip", ["192.0.2.44"]},
        {"Marble endpoint", "owned_by", ["Edge Services"]}
      ],
      serve: true
    },
    %{
      id: "serve-uk-profile-definition",
      query: "Розкажи про Drupal",
      groups: [
        {"Drupal", "is_a", ["content management system"]},
        {"Drupal", "used_for", ["building and operating websites"]}
      ],
      serve: true
    },
    %{
      id: "serve-uk-profile-service",
      query: "Розкажи про Helios AI Program",
      groups: [
        {"Helios AI Program", "is_a", ["internal AI enablement program"]},
        {"Helios AI Program", "owned_by", ["Applied Intelligence"]}
      ],
      serve: true
    },
    %{
      id: "serve-uk-known-about-profile",
      query: "Що відомо про Nimbus gateway",
      groups: [
        {"Nimbus gateway", "is_a", ["edge routing service"]},
        {"Nimbus gateway", "has_url", ["https://nimbus.example.test"]}
      ],
      serve: true
    },
    # SHOULD VETO - near-misses: loosely related facts, wrong entity, wrong relation.
    %{
      id: "veto-definition-vs-owner",
      query: "who owns the Atlas Search service",
      groups: [
        {"Atlas Search", "is_a", ["document indexing service"]},
        {"Atlas Search", "has_url", ["https://atlas.example.test"]}
      ],
      serve: false
    },
    %{
      id: "veto-owner-vs-ip",
      query: "what IP does the Beacon API use",
      groups: [
        {"Beacon API", "owned_by", ["Integration Tools"]},
        {"Beacon API", "has_url", ["https://beacon.example.test"]}
      ],
      serve: false
    },
    %{
      id: "veto-url-vs-owner",
      query: "who owns the Quill dashboard",
      groups: [
        {"Quill dashboard", "has_url", ["https://quill.example.test"]},
        {"Quill dashboard", "is_a", ["editing metrics dashboard"]}
      ],
      serve: false
    },
    %{
      id: "veto-broad-profile-wrong-entity",
      query: "Розкажи про Drupal",
      groups: [
        {"Drupa", "is_a", ["printing industry event"]},
        {"Drupa", "held_in", ["Dusseldorf"]}
      ],
      serve: false
    },
    %{
      id: "veto-specific-ip-from-broad-profile",
      query: "what IP does the Nimbus gateway use",
      groups: [
        {"Nimbus gateway", "is_a", ["edge routing service"]},
        {"Nimbus gateway", "has_url", ["https://nimbus.example.test"]}
      ],
      serve: false
    },
    %{
      id: "veto-wrong-entity-owner",
      query: "who owns the Beacon API",
      groups: [
        {"Beacon worker", "owned_by", ["Batch Operations"]},
        {"Beacon worker", "is_a", ["background job"]}
      ],
      serve: false
    },
    %{
      id: "veto-wrong-entity-url",
      query: "what is the URL for the Quill dashboard",
      groups: [
        {"Quill archive", "has_url", ["https://archive.example.test"]},
        {"Quill archive", "owned_by", ["Records"]}
      ],
      serve: false
    },
    %{
      id: "veto-related-system-ip",
      query: "what IP does the Marble endpoint use",
      groups: [
        {"Marble gateway", "has_ip", ["192.0.2.55"]},
        {"Marble gateway", "routes_to", ["Marble endpoint"]}
      ],
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
  Score the entity-profile serve/veto decision on the labelled set. `opts`: `:entail_fun`
  (default builds from `:model`/`:system`/`:generation_fun` via `Gate.entail/3` with the
  entity-profile entail system). `false_serve_rate` MUST be ~0.
  """
  @spec score(keyword()) :: report()
  def score(opts \\ []) do
    entail_fun = Keyword.get(opts, :entail_fun, &default_entity_entail(&1, &2, opts))

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

  defp default_entity_entail(q, g, opts) do
    entail_opts =
      opts
      |> Keyword.take([:model, :system, :generation_fun])
      |> Keyword.put_new(:system, Gate.entity_entail_system())

    Gate.entail(q, g, entail_opts)
  end

  defp build_descriptor(%{query: q, groups: groups}) do
    %Descriptor{
      query: q,
      intent: :entity_profile,
      entity_groups:
        Enum.map(groups, fn {subject, predicate, objects} ->
          %{
            subject: subject,
            predicate: predicate,
            objects: Enum.map(objects, &%{object: &1, corroboration: 1})
          }
        end),
      blockers: []
    }
  end

  defp served?(descriptor, entail_fun) do
    match?({:serve, _answer, _audit}, Gate.sufficient?(descriptor, entail_fun: entail_fun))
  end

  defp safe_div(_num, 0), do: 0.0
  defp safe_div(num, den), do: num / den
end
