defmodule Swarm.WorldMap.Gate.NetworkCalibration do
  @moduledoc """
  Synthetic calibration for the tier-gate's `:network` serve path (ADR-17 world-map). Mirrors
  `Swarm.WorldMap.Gate.Calibration` (procedures). The network path serves topology neighborhoods
  fast instead of escalating — but the Stage-2 entail must VETO the false-serve class the
  entity_profile path fell into: WRONG entity, WRONG relation, or a fact the grounding simply
  lacks (the live "what is the Nebula public IP" → served subnets was exactly this). Frozen,
  neutral, leak-free labels (no intranet), so a config is chosen by numbers.

  `false_serve_rate` is the HARD gate (~0). `serve_recall` is the needless-escalation complement.
  Note: the STRUCTURAL corroboration floor (only ≥2-origin facts reach here) is enforced upstream
  in `Coverage.network_descriptor`; this eval isolates the Stage-2 semantic veto.
  """

  alias Swarm.WorldMap.Coverage.Descriptor
  alias Swarm.WorldMap.Gate

  @typedoc "A labelled network case: given a subject + its facts, SHOULD the gate serve for the query?"
  @type sample :: %{
          id: String.t(),
          query: String.t(),
          subject: String.t(),
          facts: [{String.t(), String.t()}],
          serve: boolean()
        }

  @labeled [
    # SHOULD SERVE — facts state the SPECIFIC relation asked about the SAME entity
    %{
      id: "serve-tunnel-carries",
      query: "what subnets does the orbit tunnel carry",
      subject: "tunnel orbit",
      facts: [{"carries", "subnet 10.128.0.0/16"}, {"carries", "subnet 10.129.0.0/16"}],
      serve: true
    },
    %{
      id: "serve-cluster-contains",
      query: "what hosts are in the nebula-prod cluster",
      subject: "cluster nebula-prod",
      facts: [{"contains", "host node-a"}, {"contains", "host node-b"}],
      serve: true
    },
    %{
      id: "serve-tunnel-terminates",
      query: "where does the orbit tunnel terminate",
      subject: "tunnel orbit",
      facts: [{"terminates_at", "gateway peer-gw"}],
      serve: true
    },
    %{
      id: "serve-protected-by",
      query: "what firewall is web01 behind",
      subject: "host web01",
      facts: [{"protected_by", "firewall edge-fw"}],
      serve: true
    },
    # PLACEMENT — "where does this machine run". Added 2026-09-04 after the learner eval
    # found the Stage-2 entail vetoing well-formed `hosted_on` groundings: swapping only
    # the word for the machine (hypervisor <-> proxmox node) flipped 16 of 18 verdicts on
    # identical facts. The prompt enumerated relations and `hosted_on` was not among them.
    # Both phrasings are the SAME ask and must both serve.
    %{
      id: "serve-hosted-on-node-wording",
      query: "which proxmox node runs app-01",
      subject: "host app-01",
      facts: [{"hosted_on", "host hv-01"}],
      serve: true
    },
    %{
      id: "serve-hosted-on-hypervisor-wording",
      query: "which hypervisor runs app-01",
      subject: "host app-01",
      facts: [{"hosted_on", "host hv-01"}],
      serve: true
    },
    %{
      id: "serve-hosted-on-located-wording",
      query: "on which hypervisor is app-01 located",
      subject: "host app-01",
      facts: [{"hosted_on", "host hv-01"}],
      serve: true
    },
    # SHOULD VETO — wrong entity / wrong relation / a fact the grounding LACKS
    #
    # The placement clause must NOT become a licence: `hosted_on` answers WHERE something
    # runs, never WHO owns it (`veto-ownership-vs-hosting`, already in this set), and never
    # about a different machine.
    %{
      id: "veto-placement-wrong-entity",
      query: "which hypervisor runs app-02",
      subject: "host app-01",
      facts: [{"hosted_on", "host hv-01"}],
      serve: false
    },
    %{
      id: "veto-public-ip-vs-subnets",
      query: "what is the nebula public IP",
      subject: "cluster nebula-prod",
      facts: [{"contains", "host node-a"}, {"carries", "subnet 10.129.0.0/16"}],
      serve: false
    },
    %{
      id: "veto-ownership-vs-hosting",
      query: "who owns the keycloak service",
      subject: "service keycloak",
      facts: [{"hosted_on", "host node-c"}],
      serve: false
    },
    %{
      id: "veto-wrong-relation",
      query: "what subnets does the conduit tunnel carry",
      subject: "tunnel conduit",
      facts: [{"terminates_at", "gateway peer-gw"}],
      serve: false
    },
    %{
      id: "veto-wrong-entity-cluster-for-tunnel",
      query: "what subnets does the orbit tunnel carry",
      subject: "cluster nebula-prod",
      facts: [{"contains", "host node-a"}, {"contains", "host node-b"}],
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
  Score the network serve/veto decision on the labelled set. `opts`: `:entail_fun` (default builds
  from `:model` via `Gate.entail/3` with the network entail system). `false_serve_rate` MUST be ~0.
  """
  @spec score(keyword()) :: report()
  def score(opts \\ []) do
    entail_fun = Keyword.get(opts, :entail_fun, &default_net_entail(&1, &2, opts))

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

  # The network entail uses Gate's :network system prompt (routed via the default path). We build
  # the descriptor and let Gate.sufficient? pick the network system, unless a config is given.
  defp default_net_entail(q, g, opts) do
    entail_opts =
      opts
      |> Keyword.take([:model, :system])
      |> Keyword.put_new(:system, Gate.network_entail_system())

    Gate.entail(q, g, entail_opts)
  end

  defp build_descriptor(%{query: q, subject: subject, facts: facts}) do
    %Descriptor{
      query: q,
      intent: :neighborhood,
      domain: :network,
      neighborhood_subject: subject,
      neighborhood_facts:
        Enum.map(facts, fn {rel, obj} ->
          %{relation: rel, object: obj, object_kind: "entity", corroboration: 2}
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
