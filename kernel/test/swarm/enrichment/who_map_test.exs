defmodule Swarm.Enrichment.WhoMapTest do
  @moduledoc """
  E1 who-is-who substrate writer. Proves namespaced uid-keyed person identity, governed
  relation↔kind signatures, group-scope clamp (no-leak), and searchable profile content.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Enrichment.WhoMap
  alias Swarm.Graph.Store
  alias Swarm.Repo

  defp anchor, do: %{id: Store.upsert_node("source", "ldap:directory", scope: "group"), scope: "group"}

  defp fact(subj, sk, rel, obj, ok),
    do: %{subject: subj, subject_kind: sk, relation: rel, object: obj, object_kind: ok}

  defp node_id(key), do: Repo.query!("SELECT id FROM node WHERE key = $1", [key]).rows

  describe "write/4 — namespaced entities, is_a markers, governed relations" do
    test "writes uid-keyed person + team nodes, an is_a marker each, and a works_in edge" do
      ids = WhoMap.write(anchor(), [fact("jdoe", "person", "works_in", "Engineering", "team")], "p")

      # namespaced keys (team canonicalized: downcased)
      assert [[person]] = node_id("who:person:jdoe")
      assert [[team]] = node_id("who:team:engineering")

      # a works_in edge person→team exists
      assert [[_]] =
               Repo.query!(
                 "SELECT id FROM edge WHERE src = $1 AND dst = $2 AND type = 'works_in'",
                 [person, team]
               ).rows

      # is_a markers minted (person + team)
      assert node_id("who:kind:person") != []
      assert node_id("who:kind:team") != []
      # returned ids include the two is_a edges + the works_in edge
      assert length(ids) == 3
    end

    test "keys persons by uid — two same-named people (distinct uids) never collide" do
      WhoMap.write(anchor(), [fact("jmartin1", "person", "has_title", "Engineer", "role")], "p")
      WhoMap.write(anchor(), [fact("jmartin2", "person", "has_title", "Engineer", "role")], "p")

      assert [[_]] = node_id("who:person:jmartin1")
      assert [[_]] = node_id("who:person:jmartin2")
      # distinct person nodes, one shared role node
      assert Repo.query!("SELECT count(*) FROM node WHERE key LIKE 'who:person:%'").rows == [[2]]
      assert Repo.query!("SELECT count(*) FROM node WHERE key = 'who:role:engineer'").rows == [[1]]
    end

    test "a mis-typed relation↔kind fact is DROPPED (managed_by must be person→person)" do
      # managed_by whose object is a team is not admissible → no edge written
      ids = WhoMap.write(anchor(), [fact("jdoe", "person", "managed_by", "Engineering", "team")], "p")
      assert ids == []
      assert node_id("who:person:jdoe") == []
    end

    test "has_employment (person→status) and has_role_family (person→family) are governed relations" do
      ids =
        WhoMap.write(anchor(), [
          fact("jdoe", "person", "has_employment", "contractor", "status"),
          fact("jdoe", "person", "has_role_family", "developer", "family")
        ], "p")

      assert [[_]] = node_id("who:status:contractor")
      assert [[dev]] = node_id("who:family:developer")
      assert [[jdoe]] = node_id("who:person:jdoe")

      assert [[_]] =
               Repo.query!(
                 "SELECT id FROM edge WHERE src = $1 AND dst = $2 AND type = 'has_role_family'",
                 [jdoe, dev]
               ).rows

      # a mis-typed family edge (object not a family) is dropped
      assert WhoMap.write(anchor(), [fact("jdoe", "person", "has_role_family", "bob", "person")], "p") == []
      refute length(ids) == 0
    end

    test "managed_by person→person is admissible" do
      ids = WhoMap.write(anchor(), [fact("jdoe", "person", "managed_by", "bsmith", "person")], "p")
      assert [[a]] = node_id("who:person:jdoe")
      assert [[b]] = node_id("who:person:bsmith")

      assert [[_]] =
               Repo.query!(
                 "SELECT id FROM edge WHERE src = $1 AND dst = $2 AND type = 'managed_by'",
                 [a, b]
               ).rows

      assert length(ids) == 3
    end

    test "who nodes/edges are clamped to group scope (no-leak — never public)" do
      # even a public source anchor yields group-scoped who data
      pub_anchor = %{id: Store.upsert_node("source", "ldap:directory", scope: "public"), scope: "public"}
      WhoMap.write(pub_anchor, [fact("jdoe", "person", "works_in", "Eng", "team")], "p")

      assert Repo.query!("SELECT scope FROM node WHERE key = 'who:person:jdoe'").rows == [["group"]]

      assert Repo.query!(
               "SELECT DISTINCT visibility_scope FROM edge WHERE type = 'works_in'"
             ).rows == [["group"]]
    end
  end

  describe "write_profile/3 — searchable profile content" do
    test "stores allowlisted attrs as the person node's content body (name searchable)" do
      profile = %{"uid" => "jdoe", "cn" => "Jane Doe", "title" => "Engineer", "ou" => "Platform", "employment" => "contractor"}
      person = WhoMap.write_profile(profile, "p")

      assert [[body]] = Repo.query!("SELECT body FROM content WHERE node_id = $1", [person]).rows
      assert body =~ "Jane Doe"
      assert body =~ "Engineer"
      # employment category is searchable (distinguishes contractors/externals from staff)
      assert body =~ "employment: contractor"
      # keyed by uid
      assert Repo.query!("SELECT key FROM node WHERE id = $1", [person]).rows == [["who:person:jdoe"]]
    end

    test "is idempotent — a re-write updates the same single content row" do
      WhoMap.write_profile(%{"uid" => "jdoe", "cn" => "Jane Doe"}, "p")
      person = WhoMap.write_profile(%{"uid" => "jdoe", "cn" => "Jane D. Roe"}, "p")

      assert Repo.query!("SELECT count(*) FROM content WHERE node_id = $1", [person]).rows == [[1]]
      assert [[body]] = Repo.query!("SELECT body FROM content WHERE node_id = $1", [person]).rows
      assert body =~ "Jane D. Roe"
    end

    test "a missing/blank uid is refused" do
      assert WhoMap.write_profile(%{"cn" => "No Uid"}, "p") == :error
      assert WhoMap.write_profile(%{"uid" => "  "}, "p") == :error
    end
  end

  describe "neighborhood/3 — bidirectional, name-resolved serve traversal" do
    setup do
      a = anchor()
      # jdoe works_in platform, managed_by bsmith
      WhoMap.write(a, [
        fact("jdoe", "person", "works_in", "Platform", "team"),
        fact("jdoe", "person", "managed_by", "bsmith", "person")
      ], "p")
      # profiles give the resolvable display names
      WhoMap.write_profile(%{"uid" => "jdoe", "cn" => "Jane Doe"}, "p")
      WhoMap.write_profile(%{"uid" => "bsmith", "cn" => "Bob Smith"}, "p")
      :ok
    end

    test "OUTGOING from a person resolves object names (team by label, manager by cn)" do
      facts = WhoMap.neighborhood("who:person:jdoe", ["group"])
      by_rel = Map.new(facts, &{&1.relation, &1})

      assert by_rel["works_in"].object == "platform"
      assert by_rel["works_in"].object_kind == "team"
      assert by_rel["managed_by"].object == "Bob Smith"
      assert by_rel["managed_by"].object_kind == "person"
    end

    test "INCOMING to a team surfaces its members by NAME (not uid)" do
      facts = WhoMap.neighborhood("who:team:platform", ["group"])
      assert [%{relation: "works_in", object: "Jane Doe", object_kind: "person"}] = facts
    end

    test "is scope-fenced — nothing served outside the viewer's scopes" do
      assert WhoMap.neighborhood("who:person:jdoe", ["public"]) == []
    end

    test "candidates/2 resolves a person by profile NAME and a team by key" do
      # person by name (keyed by uid — name lives only in content)
      assert "who:person:jdoe" in WhoMap.candidates("who manages Jane Doe", ["group"])
      # team by canonical key tail — and it RANKS ABOVE its own members (a key-tail match weighs
      # more than a member merely mentioning the team in their profile), so "who's in team X"
      # resolves to the team (full roster) not one member (1-of-N served as if all).
      cands = WhoMap.candidates("who is in the platform team", ["group"])
      assert "who:team:platform" in cands
      assert List.first(cands) == "who:team:platform"
      # scope-fenced
      assert WhoMap.candidates("Jane Doe", ["public"]) == []
    end

    test "candidates/2 resolves role-family + employment despite plurals and 2-char acronyms" do
      a = anchor()
      WhoMap.write(a, [
        fact("jdoe", "person", "has_role_family", "developer", "family"),
        fact("hsmith", "person", "has_role_family", "hr", "family"),
        fact("csmith", "person", "has_employment", "contractor", "status")
      ], "p")

      # plural query → singular family key
      assert "who:family:developer" in WhoMap.candidates("who are the developers", ["group"])
      # 2-char acronym family (would be dropped by a ≥3 filter)
      assert "who:family:hr" in WhoMap.candidates("who works in HR", ["group"])
      # plural → singular status key
      assert "who:status:contractor" in WhoMap.candidates("who are the contractors", ["group"])
    end

    test "candidates/2 maps query-word synonyms to the family (admins→sysadmin, managers→management)" do
      a = anchor()
      WhoMap.write(a, [
        fact("s1", "person", "has_role_family", "sysadmin", "family"),
        fact("m1", "person", "has_role_family", "management", "family")
      ], "p")

      # "admins"/"managers" don't share a prefix with sysadmin/management — synonym map bridges them,
      # and the exact-tier (100) puts the FAMILY first over any look-alike title.
      assert List.first(WhoMap.candidates("who are the admins", ["group"])) == "who:family:sysadmin"
      assert List.first(WhoMap.candidates("who are the managers", ["group"])) == "who:family:management"
    end
  end
end
