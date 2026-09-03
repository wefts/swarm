defmodule Swarm.Graph.AggregationTest do
  @moduledoc """
  Entity-centric knowledge aggregation (STEP 2) — gather the claim graph about the
  query's entities, grouped by canonical predicate, corroboration-ranked,
  scope-enforced (edge + both endpoints; refuted + structural excluded; counts after
  the scope filter). Multiple objects are PRESENTED (enumeration), not auto-resolved.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.{Aggregation, Store}

  # Upsert entity nodes (idempotent on {type,key}, like the enrichment worker) so a
  # subject key can recur across claims without a duplicate-insert failure.
  defp claim!(subj_key, pred, obj_key, scope, opts \\ []) do
    s = Store.upsert_node("entity", subj_key, scope: scope)
    o = Store.upsert_node("entity", obj_key, scope: scope)
    prov = Keyword.get(opts, :provenance, "p-#{subj_key}-#{pred}-#{obj_key}")

    {:ok, %{id: id}} =
      Graph.add_edge(s, o, pred, prov,
        evidence_kind: "claim",
        scope: scope,
        origin: Keyword.get(opts, :origin, prov)
      )

    {s, o, id}
  end

  test "groups a subject's claims by canonical predicate" do
    claim!("Rancher", "is_a", "Kubernetes manager", "public")
    claim!("Rancher", "maintained_by", "Ansible", "public")

    profile = Aggregation.entity_profile("what is rancher", ["public"])
    preds = profile.groups |> Enum.filter(&(&1.subject == "Rancher")) |> Enum.map(& &1.predicate)
    assert "is a" in preds
    assert "maintained by" in preds
    g = Aggregation.to_grounding(profile)
    assert g =~ "## Rancher"
    assert g =~ "Kubernetes manager"
  end

  test "presents multiple objects under one predicate (enumeration, not auto-resolved)" do
    claim!("Google Workspace", "includes", "Gmail", "public", provenance: "p1", origin: "o1")
    claim!("Google Workspace", "includes", "Drive", "public", provenance: "p2", origin: "o2")

    profile = Aggregation.entity_profile("google workspace includes", ["public"])

    grp =
      Enum.find(
        profile.groups,
        &(&1.subject == "Google Workspace" and &1.predicate == "includes")
      )

    objects = Enum.map(grp.objects, & &1.object)
    assert "Gmail" in objects and "Drive" in objects
  end

  test "the predicate is canonicalized for display (underscores → spaces)" do
    # Relation types are contract-constrained to lowercase identifiers, so the
    # canonicalization's real job is display normalization for the consilium + defense
    # (it CAN merge if the constraint ever loosens). A single origin ⇒ corroboration 1.
    claim!("Nebula", "public_ip", "1.2.3.4", "public", origin: "o1")

    profile = Aggregation.entity_profile("nebula public ip", ["public"])
    grp = Enum.find(profile.groups, &(&1.subject == "Nebula" and &1.predicate == "public ip"))

    assert [%{object: "1.2.3.4", corroboration: 1}] =
             grp.objects |> Enum.map(&Map.take(&1, [:object, :corroboration]))
  end

  test "scope no-leak: a private claim is invisible to a public asker; counts after filter" do
    claim!("SecretSvc", "admin_password", "hunter2", "private")

    assert Aggregation.entity_profile("secretsvc admin password", ["public"]).facts == []
    facts = Aggregation.entity_profile("secretsvc admin password", ["private"]).facts
    assert Enum.any?(facts, &(&1.subject == "SecretSvc" and &1.object == "hunter2"))
  end

  test "empty scopes ⇒ empty profile (default-deny)" do
    claim!("Rancher", "is_a", "Kubernetes manager", "public")

    assert Aggregation.entity_profile("rancher", []) == %{
             groups: [],
             facts: [],
             claim_support: nil
           }
  end

  test "a refuted claim (reward < 0) is excluded" do
    {_s, _o, id} = claim!("Rancher", "is_a", "wrong", "public")
    Store.set_reward(id, -1)
    assert Aggregation.entity_profile("rancher", ["public"]).facts == []
  end

  test "structural relations (links_to/child_of) are not aggregated as facts" do
    s = add_node!(%{type: "entity", key: "Rancher", scope: "public"})
    o = add_node!(%{type: "article", key: "Some Page", scope: "public"})
    {:ok, _} = Graph.add_edge(s, o, "links_to", "p-link", evidence_kind: "claim", scope: "public")

    assert Aggregation.entity_profile("rancher", ["public"]).facts == []
  end

  test "claim_support reflects fact reliability (the calibration signal)" do
    claim!("Rancher", "is_a", "Kubernetes manager", "public")
    profile = Aggregation.entity_profile("rancher", ["public"])
    assert profile.claim_support > 0.0
  end

  test "per-predicate objects are bounded with a [+N more] marker" do
    for i <- 1..8,
        do:
          claim!("Hub", "has_service", "svc#{i}", "public", provenance: "p#{i}", origin: "o#{i}")

    profile = Aggregation.entity_profile("hub has service", ["public"])
    grp = Enum.find(profile.groups, &(&1.subject == "Hub" and &1.predicate == "has service"))
    assert length(grp.objects) == 5
    assert grp.omitted == 3
    assert Aggregation.to_grounding(profile) =~ "[+3 more]"
  end
end
