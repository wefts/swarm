defmodule Swarm.Graph.TechnologyTest do
  use Swarm.GraphCase, async: false

  alias Swarm.Graph.Store
  alias Swarm.Graph.Technology

  @scope Swarm.GraphCase.test_src()
  @other_scope Swarm.GraphCase.test_src2()

  defp article!(key, body, scope \\ @scope) do
    id = Store.upsert_node("article", key, scope: scope)
    hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    Repo.query!(
      """
      INSERT INTO content (node_id, body, body_hash, source_ref, segmenter)
      VALUES ($1, $2, $3, $4, 'test')
      """,
      [id, body, hash, "example.test/#{key}"]
    )

    id
  end

  test "candidates require scoped corpus support" do
    article!("Magento operations", "Release notes for Magento.")
    article!("Commerce stack", "Magento connects to synthetic services.")
    article!("Other scope Magento", "Magento outside the caller scope.", @other_scope)

    assert ["technology:magento"] =
             Technology.candidates("what is known about Magento?", [@scope])

    assert Technology.candidates("what is known about Magento?", [@other_scope]) == []
  end

  test "neighborhood reads scoped article evidence and keeps foreign scope out" do
    article!("Magento operations", "Release notes for Magento.")
    article!("Commerce stack", "Magento connects to synthetic services.")
    article!("Other scope Magento", "Magento outside the caller scope.", @other_scope)

    facts = Technology.neighborhood("technology:magento", [@scope])
    objects = Enum.map(facts, & &1.object)

    assert "Magento operations" in objects
    assert "Commerce stack" in objects
    refute "Other scope Magento" in objects
    assert Enum.all?(facts, &(&1.relation == "mentioned_in"))
    assert Enum.all?(facts, &(&1.corroboration == 1))
  end

  test "neighborhood enforces requested corroboration floor" do
    article!("Magento operations", "Release notes for Magento.")
    article!("Commerce stack", "Magento connects to synthetic services.")

    assert Technology.neighborhood("technology:magento", [@scope], min_corroboration: 2) == []
  end

  test "neighborhood can project reverse uses edges" do
    tech = Store.upsert_node("entity", "Magento", scope: @scope)
    service = Store.upsert_node("entity", "checkout service", scope: @scope)

    {:ok, _} =
      Store.add_edge(service, tech, "uses", "example.test/uses-magento",
        scope: @scope,
        reliability: 0.81
      )

    assert Enum.any?(
             Technology.neighborhood("technology:magento", [@scope]),
             &match?(
               %{
                 relation: "used_by",
                 object: "checkout service",
                 object_kind: "entity",
                 effective_reliability: 0.81
               },
               &1
             )
           )
  end
end
