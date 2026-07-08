defmodule Swarm.Enrichment.WhoMapTest do
  @moduledoc """
  E1 who-is-who substrate writer. Proves namespaced uid-keyed person identity, governed
  relation↔kind signatures, LDAP source scope (no-leak), and searchable profile content.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Enrichment.WhoMap
  alias Swarm.Graph.Store
  alias Swarm.Repo

  @who_scope "src:ldap"

  defp anchor,
    do: %{id: Store.upsert_node("source", "ldap:directory", scope: "group"), scope: "group"}

  defp fact(subj, sk, rel, obj, ok),
    do: %{subject: subj, subject_kind: sk, relation: rel, object: obj, object_kind: ok}

  defp node_id(key), do: Repo.query!("SELECT id FROM node WHERE key = $1", [key]).rows

  describe "write/4 — namespaced entities, is_a markers, governed relations" do
    test "models the 2-level org hierarchy: works_in ENTITY (org) + member_of TEAM" do
      ids =
        WhoMap.write(
          anchor(),
          [
            fact("jdoe", "person", "works_in", "AlterWay", "org"),
            fact("jdoe", "person", "member_of", "France / AlterWay / ops", "team")
          ],
          "p"
        )

      assert [[person]] = node_id("who:person:jdoe")
      assert [[org]] = node_id("who:org:alterway")
      assert [[team]] = node_id("who:team:france / alterway / ops")

      assert [[_]] =
               Repo.query!(
                 "SELECT id FROM edge WHERE src = $1 AND dst = $2 AND type = 'works_in'",
                 [person, org]
               ).rows

      assert [[_]] =
               Repo.query!(
                 "SELECT id FROM edge WHERE src = $1 AND dst = $2 AND type = 'member_of'",
                 [person, team]
               ).rows

      # works_in with a team-kind object is now mis-typed (entity level is org) → dropped
      assert WhoMap.write(anchor(), [fact("x", "person", "works_in", "T", "team")], "p") == []
      refute ids == []
    end

    test "keys persons by uid — two same-named people (distinct uids) never collide" do
      WhoMap.write(anchor(), [fact("jmartin1", "person", "has_title", "Engineer", "role")], "p")
      WhoMap.write(anchor(), [fact("jmartin2", "person", "has_title", "Engineer", "role")], "p")

      assert [[_]] = node_id("who:person:jmartin1")
      assert [[_]] = node_id("who:person:jmartin2")
      # distinct person nodes, one shared role node
      assert Repo.query!("SELECT count(*) FROM node WHERE key LIKE 'who:person:%'").rows == [[2]]

      assert Repo.query!("SELECT count(*) FROM node WHERE key = 'who:role:engineer'").rows == [
               [1]
             ]
    end

    test "a mis-typed relation↔kind fact is DROPPED (managed_by must be person→person)" do
      # managed_by whose object is a team is not admissible → no edge written
      ids =
        WhoMap.write(anchor(), [fact("jdoe", "person", "managed_by", "Engineering", "team")], "p")

      assert ids == []
      assert node_id("who:person:jdoe") == []
    end

    test "has_employment (person→status) and has_role_family (person→family) are governed relations" do
      ids =
        WhoMap.write(
          anchor(),
          [
            fact("jdoe", "person", "has_employment", "contractor", "status"),
            fact("jdoe", "person", "has_role_family", "developer", "family")
          ],
          "p"
        )

      assert [[_]] = node_id("who:status:contractor")
      assert [[dev]] = node_id("who:family:developer")
      assert [[jdoe]] = node_id("who:person:jdoe")

      assert [[_]] =
               Repo.query!(
                 "SELECT id FROM edge WHERE src = $1 AND dst = $2 AND type = 'has_role_family'",
                 [jdoe, dev]
               ).rows

      # a mis-typed family edge (object not a family) is dropped
      assert WhoMap.write(
               anchor(),
               [fact("jdoe", "person", "has_role_family", "bob", "person")],
               "p"
             ) == []

      refute length(ids) == 0
    end

    test "managed_by person→person is admissible" do
      ids =
        WhoMap.write(anchor(), [fact("jdoe", "person", "managed_by", "bsmith", "person")], "p")

      assert [[a]] = node_id("who:person:jdoe")
      assert [[b]] = node_id("who:person:bsmith")

      assert [[_]] =
               Repo.query!(
                 "SELECT id FROM edge WHERE src = $1 AND dst = $2 AND type = 'managed_by'",
                 [a, b]
               ).rows

      assert length(ids) == 3
    end

    test "who data nodes/edges are stamped with the LDAP source scope; markers are public" do
      # even a public source anchor yields LDAP-scoped who data
      pub_anchor = %{
        id: Store.upsert_node("source", "ldap:directory", scope: "public"),
        scope: "public"
      }

      WhoMap.write(pub_anchor, [fact("jdoe", "person", "works_in", "Eng", "org")], "p")

      assert Repo.query!("SELECT scope FROM node WHERE key = 'who:person:jdoe'").rows == [
               [@who_scope]
             ]

      assert Repo.query!("SELECT scope FROM node WHERE key = 'who:kind:person'").rows == [
               ["public"]
             ]

      assert Repo.query!("SELECT DISTINCT visibility_scope FROM edge WHERE type = 'works_in'").rows ==
               [[@who_scope]]
    end

    test "in_group (person→group) is a governed relation; group node + is_a minted" do
      ids =
        WhoMap.write(anchor(), [fact("jdoe", "person", "in_group", "alterway-ops", "group")], "p")

      assert [[person]] = node_id("who:person:jdoe")
      assert [[grp]] = node_id("who:group:alterway-ops")

      assert [[_]] =
               Repo.query!(
                 "SELECT id FROM edge WHERE src = $1 AND dst = $2 AND type = 'in_group'",
                 [person, grp]
               ).rows

      assert node_id("who:kind:group") != []

      assert Repo.query!("SELECT scope FROM node WHERE key = 'who:kind:group'").rows == [
               ["public"]
             ]

      # mis-typed: in_group object must be a group
      assert WhoMap.write(anchor(), [fact("jdoe", "person", "in_group", "bob", "person")], "p") ==
               []

      refute ids == []
    end

    test "service + managed_by_team (service→group) is governed; write_service stores content" do
      ids =
        WhoMap.write(
          anchor(),
          [fact("keycloak", "service", "managed_by_team", "dsi", "group")],
          "p"
        )

      assert [[svc]] = node_id("who:service:keycloak")
      assert [[grp]] = node_id("who:group:dsi")

      assert [[_]] =
               Repo.query!(
                 "SELECT id FROM edge WHERE src=$1 AND dst=$2 AND type='managed_by_team'",
                 [svc, grp]
               ).rows

      # mis-typed: managed_by_team object must be a group
      assert WhoMap.write(
               anchor(),
               [fact("x", "service", "managed_by_team", "bob", "person")],
               "p"
             ) == []

      # write_service stores searchable name/aliases
      s = WhoMap.write_service("keycloak", "Keycloak / SSO", ["sso"])

      assert Repo.query!("SELECT body FROM content WHERE node_id=$1", [s]).rows |> hd() |> hd() =~
               "Keycloak"

      refute ids == []
    end
  end

  describe "write_profile/3 — searchable profile content" do
    test "stores allowlisted attrs as the person node's content body (name searchable)" do
      profile = %{
        "uid" => "jdoe",
        "cn" => "Jane Doe",
        "title" => "Engineer",
        "ou" => "Platform",
        "employment" => "contractor"
      }

      person = WhoMap.write_profile(profile, "p")

      assert [[body]] = Repo.query!("SELECT body FROM content WHERE node_id = $1", [person]).rows
      assert body =~ "Jane Doe"
      assert body =~ "Engineer"
      # employment category is searchable (distinguishes contractors/externals from staff)
      assert body =~ "employment: contractor"
      # keyed by uid
      assert Repo.query!("SELECT key FROM node WHERE id = $1", [person]).rows == [
               ["who:person:jdoe"]
             ]
    end

    test "is idempotent — a re-write updates the same single content row" do
      WhoMap.write_profile(%{"uid" => "jdoe", "cn" => "Jane Doe"}, "p")
      person = WhoMap.write_profile(%{"uid" => "jdoe", "cn" => "Jane D. Roe"}, "p")

      assert Repo.query!("SELECT count(*) FROM content WHERE node_id = $1", [person]).rows == [
               [1]
             ]

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
      # jdoe member_of the platform team, managed_by bsmith
      WhoMap.write(
        a,
        [
          fact("jdoe", "person", "member_of", "Platform", "team"),
          fact("jdoe", "person", "managed_by", "bsmith", "person")
        ],
        "p"
      )

      # profiles give the resolvable display names
      WhoMap.write_profile(%{"uid" => "jdoe", "cn" => "Jane Doe"}, "p")
      WhoMap.write_profile(%{"uid" => "bsmith", "cn" => "Bob Smith"}, "p")
      :ok
    end

    test "OUTGOING from a person resolves object names (team by label, manager by cn)" do
      facts = WhoMap.neighborhood("who:person:jdoe", [@who_scope])
      by_rel = Map.new(facts, &{&1.relation, &1})

      assert by_rel["member_of"].object == "platform"
      assert by_rel["member_of"].object_kind == "team"
      assert by_rel["managed_by"].object == "Bob Smith"
      assert by_rel["managed_by"].object_kind == "person"
    end

    test "INCOMING to a team surfaces its members by NAME (not uid)" do
      facts = WhoMap.neighborhood("who:team:platform", [@who_scope])
      # incoming member_of → inverse label: the team HAS member Jane Doe (direction-aware)
      assert [%{relation: "has_member", object: "Jane Doe", object_kind: "person"}] = facts
    end

    test "is scope-fenced — nothing served outside the viewer's scopes" do
      assert WhoMap.neighborhood("who:person:jdoe", ["public"]) == []
    end

    test "direction-aware labels: a manager's INCOMING managed_by reads 'manages', not 'managed_by'" do
      # jdoe managed_by bsmith (setup) → from BSMITH's side it's an INCOMING managed_by (jdoe reports
      # to him), which must render as 'manages Jane Doe', not 'managed_by Jane Doe' (the erker bug).
      mgr = WhoMap.neighborhood("who:person:bsmith", [@who_scope])
      by_rel = Map.new(mgr, &{&1.relation, &1.object})
      assert by_rel["manages"] == "Jane Doe"
      refute Map.has_key?(by_rel, "managed_by")
      # jdoe's OWN side keeps the outgoing label
      jf =
        WhoMap.neighborhood("who:person:jdoe", [@who_scope]) |> Map.new(&{&1.relation, &1.object})

      assert jf["managed_by"] == "Bob Smith"
    end

    test "display_subject resolves a person's cn (not the uid) for the answer header" do
      assert WhoMap.display_subject("who:person:jdoe") == "Jane Doe"
      # a non-person subject falls back to the canonical tail
      assert WhoMap.display_subject("who:team:platform") == "platform"
    end

    test "candidates: a surname doesn't get hijacked by a short site code (boremchuk ≠ site 'bor')" do
      a = anchor()
      WhoMap.write(a, [fact("sboremchuk", "person", "located_at", "Bor", "site")], "p")

      WhoMap.write_profile(
        %{"uid" => "sboremchuk", "cn" => "Serhii Boremchuk", "sn" => "Boremchuk"},
        "p"
      )

      cands = WhoMap.candidates("who is boremchuk", [@who_scope])
      # the 3-char site 'bor' must NOT prefix-grab the 9-char surname; the person resolves
      refute "who:site:bor" in cands
      assert "who:person:sboremchuk" in cands
    end

    test "candidates/2 resolves a person by profile NAME and a team by key" do
      # person by name (keyed by uid — name lives only in content)
      assert "who:person:jdoe" in WhoMap.candidates("who manages Jane Doe", [@who_scope])
      # team by canonical key tail — and it RANKS ABOVE its own members (a key-tail match weighs
      # more than a member merely mentioning the team in their profile), so "who's in team X"
      # resolves to the team (full roster) not one member (1-of-N served as if all).
      cands = WhoMap.candidates("who is in the platform team", [@who_scope])
      assert "who:team:platform" in cands
      assert List.first(cands) == "who:team:platform"
      # the entity/subsidiary level ("who works in AlterWay") resolves to who:org:*
      WhoMap.write(anchor(), [fact("k", "person", "works_in", "AlterWay", "org")], "p")

      assert List.first(WhoMap.candidates("who works in AlterWay", [@who_scope])) ==
               "who:org:alterway"

      # scope-fenced
      assert WhoMap.candidates("Jane Doe", ["public"]) == []
    end

    test "candidates/2 resolves role-family + employment despite plurals and 2-char acronyms" do
      a = anchor()

      WhoMap.write(
        a,
        [
          fact("jdoe", "person", "has_role_family", "developer", "family"),
          fact("hsmith", "person", "has_role_family", "hr", "family"),
          fact("csmith", "person", "has_employment", "contractor", "status")
        ],
        "p"
      )

      # plural query → singular family key
      assert "who:family:developer" in WhoMap.candidates("who are the developers", [@who_scope])
      # 2-char acronym family (would be dropped by a ≥3 filter)
      assert "who:family:hr" in WhoMap.candidates("who works in HR", [@who_scope])
      # plural → singular status key
      assert "who:status:contractor" in WhoMap.candidates("who are the contractors", [@who_scope])
    end

    test "candidates/2 maps query-word synonyms to the family (admins→sysadmin, managers→management)" do
      a = anchor()

      WhoMap.write(
        a,
        [
          fact("s1", "person", "has_role_family", "sysadmin", "family"),
          fact("m1", "person", "has_role_family", "management", "family")
        ],
        "p"
      )

      # "admins"/"managers" don't share a prefix with sysadmin/management — synonym map bridges them,
      # and the exact-tier (100) puts the FAMILY first over any look-alike title.
      assert List.first(WhoMap.candidates("who are the admins", [@who_scope])) ==
               "who:family:sysadmin"

      assert List.first(WhoMap.candidates("who are the managers", [@who_scope])) ==
               "who:family:management"
    end
  end

  describe "curated group resolution" do
    test "a group resolves by alias PHRASE over a broad parent org" do
      a = anchor()
      # org AlterWay + a curated group whose alias is the 2-word phrase
      WhoMap.write(a, [fact("u1", "person", "works_in", "AlterWay", "org")], "p")
      WhoMap.write(a, [fact("u2", "person", "in_group", "alterway-ops", "group")], "p")
      WhoMap.write_group("alterway-ops", "AlterWay ops", ["aw ops", "ops alterway"])

      # bare entity query → the org
      assert List.first(WhoMap.candidates("who works in AlterWay", [@who_scope])) ==
               "who:org:alterway"

      # entity + qualifier → the curated group (phrase "alterway ops" in the query)
      assert List.first(WhoMap.candidates("who is in AlterWay ops", [@who_scope])) ==
               "who:group:alterway-ops"
    end

    test "phrase tier is word-boundary + punctuation-normalized" do
      a = anchor()
      WhoMap.write(a, [fact("u3", "person", "in_group", "aw-ops", "group")], "p")
      WhoMap.write_group("aw-ops", "AlterWay Ops Squad", ["aw ops", "alter-way squad"])
      # punctuation: the hyphenated alias 'alter-way squad' resolves against a spaced query
      assert List.first(WhoMap.candidates("who is in the alter way squad", [@who_scope])) ==
               "who:group:aw-ops"

      # word boundary: alias 'aw ops' must NOT fire inside 'jigsaw opsroom' (previously a hijack)
      assert WhoMap.candidates("jigsaw opsroom please", [@who_scope]) == []
    end
  end
end
