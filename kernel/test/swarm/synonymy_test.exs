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
end
