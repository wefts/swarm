defmodule Swarm.Graph.TemporalTest do
  @moduledoc """
  Temporal fact model (schema v13) — the spec's acceptance section as executable rules:
  registry-declared temporal kind, bitemporal valid/ingest time, undated-never-overrides-dated,
  late-arrival-never-overrides-current, and current ≠ history on the same fixture. Plus the
  Proxmox slice's multi-site isolation and closure-by-absence.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.Store
  alias Swarm.Graph.Temporal
  alias Swarm.Ingest
  alias Swarm.WorldMap.Domain

  @site "proxmox:casa"
  @t1 ~U[2026-09-01 10:00:00.000000Z]
  @t2 ~U[2026-09-02 10:00:00.000000Z]
  @t3 ~U[2026-09-03 10:00:00.000000Z]

  defp entity(key), do: Store.upsert_node("entity", key, scope: test_src())

  defp edge!(src, dst, type, provenance) do
    {:ok, %{id: id}} =
      Store.add_edge(src, dst, type, provenance, scope: test_src(), origin: provenance)

    id
  end

  defp intervals(edge_id) do
    Repo.query!(
      "SELECT valid_from, valid_to, observed_at, closed_reason, absent_at, source FROM edge_validity WHERE edge_id = $1 ORDER BY valid_from NULLS FIRST",
      [edge_id]
    ).rows
  end

  setup do
    vm = entity("net:host:casa/web-01")
    a = entity("net:host:casa/pve-a")
    b = entity("net:host:casa/pve-b")

    %{
      vm: vm,
      a: a,
      b: b,
      ab: edge!(vm, a, "hosted_on", "obs-a"),
      bb: edge!(vm, b, "hosted_on", "obs-b")
    }
  end

  describe "registry contract" do
    test "every governed relation declares a temporal kind, and state relations a supersession key" do
      for rel <- Domain.structural_relations() do
        assert rel.temporal in [:state, :event, :invariant], "#{rel.key} has no temporal kind"

        if rel.temporal == :state do
          assert rel.supersession in [:subject_relation, :subject_relation_object],
                 "#{rel.key} is state without a supersession key"
        else
          assert is_nil(rel.supersession)
        end
      end

      assert Domain.temporal("hosted_on") == %{kind: :state, supersession: :subject_relation}

      assert Domain.temporal("contains") == %{
               kind: :state,
               supersession: :subject_relation_object
             }

      assert Domain.temporal("instance_of") == %{kind: :invariant, supersession: nil}
      assert Domain.temporal("links_to") == nil
    end

    test "an event, invariant, or ungoverned relation never gets an interval", %{vm: vm, a: a} do
      links = edge!(vm, a, "links_to", "page-1")
      alias_edge = edge!(vm, a, "alias_of", "page-2")

      assert {:ok, :untimed} = Temporal.assert(links, valid_time: @t1, source: @site)
      assert {:ok, :untimed} = Temporal.assert(alias_edge, valid_time: @t1, source: @site)
      assert intervals(links) == []
      assert intervals(alias_edge) == []
    end
  end

  describe "proof 1 — two runs, no drift" do
    test "re-asserting an unchanged fact keeps one interval whose valid time advances", %{ab: ab} do
      assert {:ok, :opened} = Temporal.assert(ab, valid_time: @t1, source: @site)
      assert {:ok, :extended} = Temporal.assert(ab, valid_time: @t2, source: @site)

      assert [[@t1, nil, @t2, nil, nil, @site]] = intervals(ab)

      assert [%{object: "net:host:casa/pve-a", dated?: true, valid_from: @t1, observed_at: @t2}] =
               Temporal.current("net:host:casa/web-01", "hosted_on")
    end

    test "valid time and ingest time are recorded separately", %{ab: ab} do
      {:ok, _} = Temporal.assert(ab, valid_time: @t1, source: @site)

      %{rows: [[recorded_at]]} =
        Repo.query!("SELECT recorded_at FROM edge_validity WHERE edge_id = $1", [ab])

      # the source said "true at t1" (a year-agnostic fixture instant); Swarm learned it now
      assert DateTime.compare(recorded_at, @t1) == :gt
    end
  end

  describe "proof 2 — supersession" do
    test "a newer dated value closes the old interval; both remain readable as history",
         %{ab: ab, bb: bb} do
      {:ok, :opened} = Temporal.assert(ab, valid_time: @t1, source: @site)
      {:ok, :opened} = Temporal.assert(bb, valid_time: @t2, source: @site)

      assert [[@t1, @t2, @t1, "superseded", nil, @site]] = intervals(ab)
      assert [[@t2, nil, @t2, nil, nil, @site]] = intervals(bb)

      # current and history DIFFER on the same fixture
      assert [%{object: "net:host:casa/pve-b", dated?: true}] =
               Temporal.current("net:host:casa/web-01", "hosted_on")

      assert [%{object: "net:host:casa/pve-a", valid_to: @t2}, %{object: "net:host:casa/pve-b"}] =
               Temporal.history("net:host:casa/web-01", "hosted_on")

      # and the old fact is still answerable AS OF its own time
      assert [%{object: "net:host:casa/pve-a"}] =
               Temporal.current("net:host:casa/web-01", "hosted_on", at: @t1)

      assert %{status: :superseded} =
               Temporal.check("net:host:casa/web-01", "hosted_on", "net:host:casa/pve-a")

      assert %{status: :current} =
               Temporal.check("net:host:casa/web-01", "hosted_on", "net:host:casa/pve-b")
    end

    test "the same fact can be true in disjoint intervals (A→B→A)", %{ab: ab, bb: bb} do
      {:ok, _} = Temporal.assert(ab, valid_time: @t1, source: @site)
      {:ok, _} = Temporal.assert(bb, valid_time: @t2, source: @site)
      {:ok, :opened} = Temporal.assert(ab, valid_time: @t3, source: @site)

      assert [[@t1, @t2, @t1, "superseded", nil, _], [@t3, nil, @t3, nil, nil, _]] = intervals(ab)
      assert [[@t2, @t3, @t2, "superseded", nil, _]] = intervals(bb)
    end
  end

  describe "spec — undated and late-arriving facts" do
    test "an undated state fact cannot override a dated one", %{ab: ab, bb: bb} do
      {:ok, :opened} = Temporal.assert(ab, valid_time: @t1, source: @site)
      {:ok, :undated} = Temporal.assert(bb, valid_time: nil, source: "wiki:page:9")

      # the dated fact stays current and open; the undated one is recorded but not current
      assert [[@t1, nil, @t1, nil, nil, @site]] = intervals(ab)
      assert [[nil, nil, nil, nil, nil, "wiki:page:9"]] = intervals(bb)

      assert [%{object: "net:host:casa/pve-a", dated?: true}] =
               Temporal.current("net:host:casa/web-01", "hosted_on")

      # a later DATED fact for the other object supersedes both the dated and the undated ones
      {:ok, :extended} = Temporal.assert(bb, valid_time: @t2, source: "wiki:page:9")
      assert [[@t1, @t2, @t1, "superseded", nil, @site]] = intervals(ab)
      assert [[nil, nil, @t2, nil, nil, "wiki:page:9"]] = intervals(bb)
    end

    test "only undated evidence answers as undated, with lower temporal confidence", %{bb: bb} do
      {:ok, :undated} = Temporal.assert(bb, valid_time: nil, source: "wiki:page:9")

      # both the explicit undated interval and the legacy interval-less edge answer, undated
      current = Temporal.current("net:host:casa/web-01", "hosted_on")
      assert Enum.map(current, & &1.dated?) == [false, false]
      assert %{source: "wiki:page:9"} = Enum.find(current, &(&1.object == "net:host:casa/pve-b"))

      assert %{status: :undated} =
               Temporal.check("net:host:casa/web-01", "hosted_on", "net:host:casa/pve-b")
    end

    test "a legacy edge with no interval reads as an undated candidate, superseded once a dated fact exists",
         %{ab: ab} do
      # `bb` has no interval rows at all (pre-v13 data); it is an undated candidate…
      assert [
               %{object: "net:host:casa/pve-a", dated?: false},
               %{object: "net:host:casa/pve-b", dated?: false}
             ] =
               Temporal.current("net:host:casa/web-01", "hosted_on")

      # …until a dated fact on the key exists; then only the dated fact is current
      {:ok, _} = Temporal.assert(ab, valid_time: @t1, source: @site)

      assert [%{object: "net:host:casa/pve-a", dated?: true}] =
               Temporal.current("net:host:casa/web-01", "hosted_on")

      assert %{status: :superseded} =
               Temporal.check("net:host:casa/web-01", "hosted_on", "net:host:casa/pve-b")
    end

    test "a late-arriving historical fact cannot override newer current state", %{ab: ab, bb: bb} do
      {:ok, :opened} = Temporal.assert(ab, valid_time: @t3, source: @site)
      {:ok, :historical} = Temporal.assert(bb, valid_time: @t1, source: "iac:repo")

      assert [[@t3, nil, @t3, nil, nil, @site]] = intervals(ab)
      assert [[@t1, @t3, @t1, "superseded", nil, "iac:repo"]] = intervals(bb)

      assert [%{object: "net:host:casa/pve-a"}] =
               Temporal.current("net:host:casa/web-01", "hosted_on")

      assert [%{object: "net:host:casa/pve-b"}] =
               Temporal.current("net:host:casa/web-01", "hosted_on", at: @t2)
    end
  end

  describe "proof 3 — disappearance is closure, not deletion" do
    test "a fact the source stopped returning is closed at its last observation; the run instant is kept",
         %{ab: ab, bb: bb} do
      # only the live fact exists here (no legacy candidate to answer undated)
      Repo.query!("DELETE FROM edge WHERE id = $1", [bb])
      {:ok, _} = Temporal.assert(ab, valid_time: @t1, source: @site)
      Process.sleep(5)
      run_started = DateTime.utc_now()
      as_of = @t2

      assert {:ok, 1} = Temporal.reconcile_absent(@site, run_started, as_of)
      assert [[@t1, @t1, @t1, "absent", @t2, @site]] = intervals(ab)

      assert Temporal.current("net:host:casa/web-01", "hosted_on") == []

      assert [%{object: "net:host:casa/pve-a", closed_reason: "absent", absent_at: @t2}] =
               Temporal.history("net:host:casa/web-01", "hosted_on")

      assert %{status: :closed} =
               Temporal.check("net:host:casa/web-01", "hosted_on", "net:host:casa/pve-a")
    end

    test "a fact re-attested during the run is not closed; another source's facts are untouched",
         %{ab: ab, bb: bb} do
      {:ok, _} = Temporal.assert(bb, valid_time: @t1, source: "proxmox:idf")
      Process.sleep(5)
      run_started = DateTime.utc_now()
      {:ok, _} = Temporal.assert(ab, valid_time: @t2, source: @site)

      assert {:ok, 0} = Temporal.reconcile_absent(@site, run_started, @t2)
      assert [[@t2, nil, @t2, nil, nil, @site]] = intervals(ab)
      # idf's interval was superseded by casa's dated fact on the same key (world-level), not
      # closed by casa's absence pass (source-level) — reason says which
      assert [[@t1, @t2, @t1, "superseded", nil, "proxmox:idf"]] = intervals(bb)
    end
  end

  describe "proof 4 — site isolation" do
    test "same-named subjects in two sites are two subjects with independent state" do
      casa_vm = entity("net:host:casa/web-01")
      idf_vm = entity("net:host:idf/web-01")
      casa_node = entity("net:host:casa/pve-a")
      idf_node = entity("net:host:idf/pve-a")
      refute casa_vm == idf_vm

      e_casa = edge!(casa_vm, casa_node, "hosted_on", "casa-obs")
      e_idf = edge!(idf_vm, idf_node, "hosted_on", "idf-obs")

      {:ok, :opened} = Temporal.assert(e_casa, valid_time: @t1, source: "proxmox:casa")
      {:ok, :opened} = Temporal.assert(e_idf, valid_time: @t2, source: "proxmox:idf")

      assert [[@t1, nil, @t1, nil, nil, "proxmox:casa"]] = intervals(e_casa)
      assert [[@t2, nil, @t2, nil, nil, "proxmox:idf"]] = intervals(e_idf)

      # closing casa's world does nothing to idf's
      Process.sleep(5)
      assert {:ok, 1} = Temporal.reconcile_absent("proxmox:casa", DateTime.utc_now(), @t3)
      assert [[@t2, nil, @t2, nil, nil, "proxmox:idf"]] = intervals(e_idf)
    end
  end

  describe "identity across sources (proof 5 mechanics)" do
    test "a claim about a host named one way by a document and another by a live source is one subject via alias_of",
         %{vm: vm, a: a} do
      # the document's undated claim: web-01 (documented name) hosted_on pve-a
      doc_vm = entity("net:host:web-01.casa.example.test")
      doc_edge = edge!(doc_vm, a, "hosted_on", "wiki:page:7")
      {:ok, :undated} = Temporal.assert(doc_edge, valid_time: nil, source: "wiki:page:7")

      # before the identity link the documented claim is only its own undated evidence
      assert %{status: :undated} =
               Temporal.check(
                 "net:host:web-01.casa.example.test",
                 "hosted_on",
                 "net:host:casa/pve-a"
               )

      # the identity assertion (operator curation / ER): alias_of, an invariant identity edge
      {:ok, _} =
        Store.add_edge(vm, doc_vm, "alias_of", "curation-1", scope: "private", origin: "curation")

      # the live source says web-01 is on pve-a, dated → the documented claim is CURRENT
      {:ok, :opened} =
        Temporal.assert(edge!(vm, a, "hosted_on", "obs-a"), valid_time: @t1, source: @site)

      assert %{status: :current, fact: %{dated?: true, observed_at: @t1}} =
               Temporal.check(
                 "net:host:web-01.casa.example.test",
                 "hosted_on",
                 "net:host:casa/pve-a"
               )

      # the live source later sees it on pve-b → the documented claim is SUPERSEDED
      bb = edge!(vm, entity("net:host:casa/pve-b"), "hosted_on", "obs-b")
      {:ok, :opened} = Temporal.assert(bb, valid_time: @t2, source: @site)

      assert %{status: :superseded, current: [%{object: "net:host:casa/pve-b"}]} =
               Temporal.check(
                 "net:host:web-01.casa.example.test",
                 "hosted_on",
                 "net:host:casa/pve-a"
               )
    end

    test "a node merge re-keys the intervals of repointed edges so later supersession still finds them" do
      alias_vm = entity("net:host:casa/web-01-old")
      canonical = entity("net:host:casa/web-01")
      node_c = entity("net:host:casa/pve-c")
      node_b = entity("net:host:casa/pve-b")

      # no collision: the survivor has no edge to pve-c yet
      e_alias = edge!(alias_vm, node_c, "hosted_on", "obs-alias")
      {:ok, :opened} = Temporal.assert(e_alias, valid_time: @t1, source: @site)

      assert {:ok, %{result: :merged}} =
               Store.merge_nodes("entity", "net:host:casa/web-01-old", "net:host:casa/web-01")

      # the interval now keys on the survivor…
      %{rows: [[key]]} =
        Repo.query!("SELECT supersession_key FROM edge_validity WHERE edge_id = $1", [e_alias])

      assert String.starts_with?(key, "#{canonical}|hosted_on|")

      # …so a newer fact on the survivor supersedes it
      e_b = edge!(canonical, node_b, "hosted_on", "obs-b")
      {:ok, :opened} = Temporal.assert(e_b, valid_time: @t2, source: @site)
      assert [[@t1, @t2, @t1, "superseded", nil, _]] = intervals(e_alias)
    end

    test "a merge that collides on the natural key carries the alias edge's history onto the survivor",
         %{ab: ab} do
      alias_vm = entity("net:host:casa/web-01-old")
      node_a = entity("net:host:casa/pve-a")

      # survivor edge (setup's `ab`) has a dated interval from the live source; the alias edge has
      # an older wiki interval and a duplicate live observation
      {:ok, :opened} = Temporal.assert(ab, valid_time: @t2, source: @site)
      e_alias = edge!(alias_vm, node_a, "hosted_on", "obs-alias")
      {:ok, :undated} = Temporal.assert(e_alias, valid_time: nil, source: "wiki:page:3")
      {:ok, :opened} = Temporal.assert(e_alias, valid_time: @t3, source: @site)

      assert {:ok, %{result: :merged}} =
               Store.merge_nodes("entity", "net:host:casa/web-01-old", "net:host:casa/web-01")

      # the alias edge is gone, its wiki history lives on the survivor, the duplicate live
      # observation was dropped (same source, overlapping)
      assert Repo.query!("SELECT count(*) FROM edge WHERE id = $1", [e_alias]).rows == [[0]]

      assert [[nil, nil, nil, nil, nil, "wiki:page:3"], [@t2, nil, @t2, nil, nil, @site]] =
               intervals(ab)
    end
  end

  describe "many-valued state relations" do
    test "each object is its own state: a second member does not supersede the first" do
      cluster = entity("net:cluster:casa")
      n1 = entity("net:host:casa/pve-a")
      n2 = entity("net:host:casa/pve-b")
      e1 = edge!(cluster, n1, "contains", "c-1")
      e2 = edge!(cluster, n2, "contains", "c-2")

      {:ok, :opened} = Temporal.assert(e1, valid_time: @t1, source: @site)
      {:ok, :opened} = Temporal.assert(e2, valid_time: @t2, source: @site)

      assert [[@t1, nil, @t1, nil, nil, _]] = intervals(e1)
      assert [[@t2, nil, @t2, nil, nil, _]] = intervals(e2)
      assert length(Temporal.current("net:cluster:casa", "contains")) == 2
    end

    test "a dated member does not demote an undated claim about a DIFFERENT member" do
      cluster = entity("net:cluster:casa")
      live = entity("net:host:casa/pve-a")
      documented = entity("net:host:casa/pve-legacy")
      e_live = edge!(cluster, live, "contains", "obs-1")
      _e_doc = edge!(cluster, documented, "contains", "iac:inventory")

      {:ok, :opened} = Temporal.assert(e_live, valid_time: @t1, source: @site)

      # both members are current: the live one dated, the documented one undated (unconfirmed)
      assert [
               %{object: "net:host:casa/pve-a", dated?: true},
               %{object: "net:host:casa/pve-legacy", dated?: false}
             ] =
               Temporal.current("net:cluster:casa", "contains")

      assert %{status: :undated} =
               Temporal.check("net:cluster:casa", "contains", "net:host:casa/pve-legacy")

      assert %{status: :current} =
               Temporal.check("net:cluster:casa", "contains", "net:host:casa/pve-a")
    end
  end

  describe "ingest boundary" do
    setup do
      register_test_sources!()
      :ok
    end

    defp event(provenance, site, node, opts) do
      %{
        provenance: provenance,
        origin: "proxmox:#{site}:vm:101",
        source: "proxmox:#{site}",
        occurred_at: Keyword.get(opts, :at, @t1),
        valid_time: Keyword.get(opts, :valid_time),
        entities: [
          %{type: "entity", key: "net:host:#{site}/web-01", scope: test_src()},
          %{type: "entity", key: "net:host:#{site}/#{node}", scope: test_src()}
        ],
        relations: [
          %{from: "net:host:#{site}/web-01", to: "net:host:#{site}/#{node}", type: "hosted_on"}
        ]
      }
    end

    test "valid_time on the event opens a dated interval; a second run advances it; a move supersedes" do
      assert {:ok, :written} = Ingest.ingest(event("casa@1", "casa", "pve-a", valid_time: @t1))
      assert {:ok, :written} = Ingest.ingest(event("casa@2", "casa", "pve-a", valid_time: @t2))

      assert [
               %{
                 object: "net:host:casa/pve-a",
                 valid_from: @t1,
                 observed_at: @t2,
                 source: "proxmox:casa"
               }
             ] =
               Temporal.current("net:host:casa/web-01", "hosted_on")

      assert {:ok, :written} = Ingest.ingest(event("casa@3", "casa", "pve-b", valid_time: @t3))

      assert [%{object: "net:host:casa/pve-b", valid_from: @t3}] =
               Temporal.current("net:host:casa/web-01", "hosted_on")

      assert length(Temporal.history("net:host:casa/web-01", "hosted_on")) == 2
    end

    test "an ISO valid_time string is accepted; a naive one is quarantined; absent means undated" do
      assert {:ok, :written} =
               Ingest.ingest(
                 event("iso", "casa", "pve-a", valid_time: "2026-09-01T10:00:00+02:00")
               )

      assert [%{valid_from: ~U[2026-09-01 08:00:00.000000Z]}] =
               Temporal.current("net:host:casa/web-01", "hosted_on")

      assert {:error, {:quarantined, {:bad_timestamp, _}}} =
               Ingest.ingest(event("naive", "idf", "pve-a", valid_time: "2026-09-01T10:00:00"))

      assert {:ok, :written} = Ingest.ingest(event("undated", "idf", "pve-a", []))

      assert [%{dated?: false, source: "proxmox:idf"}] =
               Temporal.current("net:host:idf/web-01", "hosted_on")
    end

    test "same-named subjects from two sites never merge" do
      assert {:ok, :written} = Ingest.ingest(event("c", "casa", "pve-a", valid_time: @t1))
      assert {:ok, :written} = Ingest.ingest(event("i", "idf", "pve-z", valid_time: @t1))

      %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM node WHERE key LIKE '%/web-01'")
      assert n == 2

      assert [%{object: "net:host:casa/pve-a"}] =
               Temporal.current("net:host:casa/web-01", "hosted_on")

      assert [%{object: "net:host:idf/pve-z"}] =
               Temporal.current("net:host:idf/web-01", "hosted_on")
    end
  end
end
