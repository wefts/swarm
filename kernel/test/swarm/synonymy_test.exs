defmodule Swarm.SynonymyTest do
  @moduledoc """
  Concept-synonymy resolution (workspace ADR-17 substrate; blackboard council
  2026-07-04). Synonyms fold onto a canonical via a REVERSIBLE `synonym_of` edge —
  NOT the destructive entity-merge (council: distinct mechanism, alias-not-collapse).
  Slice 1: the algorithmic acronym/numeronym signal + the reversible edge + the
  query-time form resolver. Scope-enforced; polysemy stays representable (a form may
  carry `synonym_of` to more than one canonical).
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Synonymy
  alias Swarm.Graph.Store

  describe "acronym?/2 — the algorithmic independent signal (no LLM, no vector)" do
    test "classic initialisms" do
      assert Synonymy.acronym?("SSP", "Self Service Password")
      assert Synonymy.acronym?("ssp", "self-service password")
      assert Synonymy.acronym?("SSO", "Single Sign-On")
      # polysemy is NOT this function's job — structural match holds for BOTH senses
      assert Synonymy.acronym?("SSP", "Supply Side Platform")
    end

    test "numeronyms (first + inner-count + last)" do
      assert Synonymy.acronym?("k8s", "Kubernetes")
      assert Synonymy.acronym?("i18n", "internationalization")
      assert Synonymy.acronym?("K8S", "kubernetes")
    end

    test "rejects non-acronym pairs (the sibling/unrelated risk)" do
      refute Synonymy.acronym?("React", "Vue")
      refute Synonymy.acronym?("LDAP", "LDAPS")
      refute Synonymy.acronym?("Kubernetes", "Rancher")
      # a wrong expansion: initials don't line up
      refute Synonymy.acronym?("SSP", "Self Password Service Extra")
      refute Synonymy.acronym?("", "anything")
      refute Synonymy.acronym?("abc", "")
    end
  end

  describe "link/3 + forms/2 — reversible synonym_of, query-time resolution" do
    setup do
      canon = Store.upsert_node("concept", "Self Service Password", scope: "group")
      alias_n = Store.upsert_node("concept", "SSP", scope: "group")
      %{canon: canon, alias_n: alias_n}
    end

    test "links a surface form to its canonical and resolves both ways", %{} do
      assert {:ok, _} = Synonymy.link("SSP", "Self Service Password", scope: "group")

      # querying EITHER surface form resolves to the full synonym set
      set = Synonymy.forms("SSP", ["group"]) |> Enum.sort()
      assert set == ["SSP", "Self Service Password"]
      assert Synonymy.forms("Self Service Password", ["group"]) |> Enum.sort() == set
    end

    test "an unlinked form resolves to just itself" do
      assert Synonymy.forms("SSP", ["group"]) == ["SSP"]
    end

    test "reversible — unlink drops the mapping (kill-and-rebuild / rollback)" do
      {:ok, _} = Synonymy.link("SSP", "Self Service Password", scope: "group")
      assert length(Synonymy.forms("SSP", ["group"])) == 2
      :ok = Synonymy.unlink("SSP", "Self Service Password", scope: "group")
      assert Synonymy.forms("SSP", ["group"]) == ["SSP"]
    end

    test "scope-enforced — a group synonym never resolves for a public-only reader" do
      {:ok, _} = Synonymy.link("SSP", "Self Service Password", scope: "group")
      assert Synonymy.forms("SSP", ["public"]) == ["SSP"]
      assert Synonymy.forms("SSP", ["public", "group"]) |> length() == 2
    end

    test "link refuses a cross-scope pair (no-leak — mirror ER's cross-scope refusal)" do
      Store.upsert_node("concept", "PublicTerm", scope: "public")
      Store.upsert_node("concept", "GroupTerm", scope: "group")
      assert {:error, :cross_scope} = Synonymy.link("GroupTerm", "PublicTerm")
    end
  end

  describe "review-hardening (code review 2026-07-04)" do
    setup do
      Store.upsert_node("concept", "Self Service Password", scope: "group")
      Store.upsert_node("concept", "SSP", scope: "group")
      Store.upsert_node("concept", "SS Password", scope: "group")
      :ok
    end

    test "forms/2 is the TRANSITIVE closure — any member resolves the full set" do
      {:ok, _} = Synonymy.link("SSP", "Self Service Password")
      {:ok, _} = Synonymy.link("SS Password", "Self Service Password")

      expected = ["SS Password", "SSP", "Self Service Password"]
      # from the alias that is NOT directly linked to the other alias:
      assert Synonymy.forms("SSP", ["group"]) |> Enum.sort() == expected
      assert Synonymy.forms("SS Password", ["group"]) |> Enum.sort() == expected
      assert Synonymy.forms("Self Service Password", ["group"]) |> Enum.sort() == expected
    end

    test "orientation-independent: link(a,b) and link(b,a) is ONE edge, unlink drops it" do
      {:ok, _} = Synonymy.link("SSP", "Self Service Password")
      {:ok, _} = Synonymy.link("Self Service Password", "SSP")

      [[n]] =
        Swarm.Repo.query!("SELECT count(*) FROM edge WHERE type = 'synonym_of'").rows

      assert n == 1
      # unlink in the OTHER order still removes it
      :ok = Synonymy.unlink("Self Service Password", "SSP")
      assert Synonymy.forms("SSP", ["group"]) == ["SSP"]
    end

    test "link rejects a self-synonym" do
      assert {:error, :self_link} = Synonymy.link("SSP", "SSP")
    end

    test "forms/2 is type-pure — a cross-type synonym_of edge never leaks another type's key" do
      # a malformed/legacy edge concept→article
      c = Store.upsert_node("concept", "SSP", scope: "group")
      a = Store.upsert_node("article", "Some Article", scope: "group")

      {:ok, _} =
        Store.add_edge(c, a, "synonym_of", "legacy", scope: "group", evidence_kind: "derived")

      refute "Some Article" in Synonymy.forms("SSP", ["group"])
    end
  end

  describe "expand_query/3 — query-time expansion (slice 2)" do
    setup do
      Store.upsert_node("concept", "SSP", scope: "group")
      Store.upsert_node("concept", "Self Service Password", scope: "group")
      {:ok, _} = Synonymy.link("SSP", "Self Service Password")
      :ok
    end

    test "a query naming an acronym gains the canonical's surface tokens" do
      out = Synonymy.expand_query("how do i reset my SSP", ["group"])
      assert out =~ "Self Service Password"
      assert out =~ "SSP"
    end

    test "case-insensitive match (query token 'ssp' finds node 'SSP')" do
      assert Synonymy.expand_query("reset ssp today", ["group"]) =~ "Self Service Password"
    end

    test "no expansion when the query names no linked concept — unchanged" do
      assert Synonymy.expand_query("how do i reset my laptop", ["group"]) ==
               "how do i reset my laptop"
    end

    test "scope-enforced — a public-only reader gets no group synonym expansion" do
      assert Synonymy.expand_query("reset my SSP", ["public"]) == "reset my SSP"
    end

    test "empty scopes ⇒ query unchanged (default-deny)" do
      assert Synonymy.expand_query("reset my SSP", []) == "reset my SSP"
    end

    test "a REFUTED synonym edge (reward<0) no longer expands (code review)" do
      # refute the synonym_of edge; retrieval read paths exclude reward<0
      %{rows: [[eid]]} =
        Swarm.Repo.query!("SELECT id FROM edge WHERE type = 'synonym_of' LIMIT 1")

      Swarm.Graph.Store.set_reward(eid, -1.0)
      assert Synonymy.expand_query("reset my SSP", ["group"]) == "reset my SSP"
      refute Synonymy.forms("SSP", ["group"]) == ["SSP", "Self Service Password"]
    end

    test "a multi-word form already fully present is NOT re-added (code review)" do
      # all tokens of "Self Service Password" already in the query → no re-add
      out = Synonymy.expand_query("reset my Self Service Password now", ["group"])
      # 'SSP' is the only form whose tokens aren't all present → it may be added;
      # 'Self Service Password' must NOT be duplicated
      assert out |> String.split() |> Enum.count(&(&1 == "Service")) == 1
    end
  end

  describe "propose_acronyms/1 + run_acronym_pass/1 (slice 3 — automated proposer)" do
    setup do
      Store.upsert_node("concept", "SSP", scope: "group")
      Store.upsert_node("concept", "Self Service Password", scope: "group")
      :ok
    end

    test "proposes an acronym pair among existing concept nodes" do
      [c] = Synonymy.propose_acronyms([])
      assert c.alias_key == "SSP"
      assert c.canonical_key == "Self Service Password"
      assert c.scope == "group"
    end

    test "does not propose an already-linked pair" do
      {:ok, _} = Synonymy.link("SSP", "Self Service Password")
      assert Synonymy.propose_acronyms([]) == []
    end

    test "a sibling_of edge auto-rejects the pair (contrastive guard, council gemini)" do
      a = Synonymy.node_id!("concept", "SSP")
      b = Synonymy.node_id!("concept", "Self Service Password")

      {:ok, _} =
        Store.add_edge(a, b, "sibling_of", "contrast", scope: "group", evidence_kind: "derived")

      assert Synonymy.propose_acronyms([]) == []
    end

    test "cross-scope acronym pairs are never proposed (no-leak)" do
      Store.upsert_node("concept", "MFA", scope: "group")
      Store.upsert_node("concept", "Multi Factor Authentication", scope: "public")
      cands = Synonymy.propose_acronyms([])
      refute Enum.any?(cands, &(&1.alias_key == "MFA"))
    end

    test "run pass links only confirmed candidates (injected confirm)" do
      yes = fn _pair -> true end
      assert %{proposed: 1, linked: 1} = Synonymy.run_acronym_pass(confirm_fun: yes)
      assert Synonymy.forms("SSP", ["group"]) |> Enum.sort() == ["SSP", "Self Service Password"]
    end

    test "run pass links nothing when the confirm rejects (precision-first)" do
      no = fn _pair -> false end
      assert %{proposed: 1, linked: 0} = Synonymy.run_acronym_pass(confirm_fun: no)
      assert Synonymy.forms("SSP", ["group"]) == ["SSP"]
    end

    test "POLYSEMY: a short form matching two expansions in one scope proposes NEITHER" do
      # SSP ⇒ "Self Service Password" (setup) AND "Supply Side Platform" — ambiguous
      Store.upsert_node("concept", "Supply Side Platform", scope: "group")
      cands = Synonymy.propose_acronyms([])
      refute Enum.any?(cands, &(&1.alias_key == "SSP"))
    end

    test "component-aware sibling guard: link refused when a sibling spans the components" do
      # SSP synonym_of Self Service Password (existing); Supply Side Platform sibling_of
      # Self Service Password → linking SSP↔Supply Side Platform would fold a sibling in
      {:ok, _} = Synonymy.link("SSP", "Self Service Password")
      ssp2 = Store.upsert_node("concept", "Supply Side Platform", scope: "group")
      ssp_canon = Synonymy.node_id!("concept", "Self Service Password")

      {:ok, _} =
        Store.add_edge(ssp2, ssp_canon, "sibling_of", "contrast",
          scope: "group",
          evidence_kind: "derived"
        )

      assert {:error, :sibling_conflict} = Synonymy.link("SSP", "Supply Side Platform")
    end
  end
end
