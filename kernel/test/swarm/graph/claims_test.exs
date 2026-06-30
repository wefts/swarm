defmodule Swarm.Graph.ClaimsTest do
  @moduledoc """
  Claim-aware answering — surface enrichment claim-graph facts for the query's
  entities, scope-enforced (the edge's own visibility_scope AND both endpoints must
  be in the asker's scopes), refuted excluded.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.{Claims, Store}

  defp claim!(subj_key, pred, obj_key, scope) do
    s = add_node!(%{type: "entity", key: subj_key, scope: scope})
    o = add_node!(%{type: "entity", key: obj_key, scope: scope})

    {:ok, %{id: id}} =
      Graph.add_edge(s, o, pred, "p-#{subj_key}", evidence_kind: "claim", scope: scope)

    {s, o, id}
  end

  test "surfaces a claim fact whose subject matches a query term" do
    claim!("Nebula", "public_ip", "203.0.113.7", "public")

    facts = Claims.for_query("what is the nebula public ip", ["public"])

    assert Enum.any?(
             facts,
             &(&1.subject == "Nebula" and &1.predicate == "public_ip" and
                 &1.object == "203.0.113.7")
           )
  end

  test "scope no-leak: a private claim is invisible to a public asker" do
    claim!("SecretSvc", "admin_password", "hunter2", "private")

    assert Claims.for_query("secretsvc admin password", ["public"]) == []
    facts = Claims.for_query("secretsvc admin password", ["private"])
    assert Enum.any?(facts, &(&1.subject == "SecretSvc" and &1.object == "hunter2"))
  end

  test "empty scopes ⇒ no facts (default-deny)" do
    claim!("Nebula", "public_ip", "203.0.113.7", "public")
    assert Claims.for_query("nebula public ip", []) == []
  end

  test "a refuted claim (reward < 0) is excluded" do
    {_s, _o, id} = claim!("Nebula", "public_ip", "wrong", "public")
    Store.set_reward(id, -1)
    assert Claims.for_query("nebula public ip", ["public"]) == []
  end

  test "to_grounding renders facts as lines; empty ⇒ blank" do
    assert Claims.to_grounding([]) == ""

    g = Claims.to_grounding([%{subject: "Nebula", predicate: "public_ip", object: "203.0.113.7"}])
    assert g =~ "Known facts"
    assert g =~ "Nebula public_ip 203.0.113.7"
  end
end
