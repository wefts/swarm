defmodule Swarm.EntityResolution.CandidatesTest do
  @moduledoc """
  Entity-resolution ER-2 — candidate proposal under the two-signal hard gate. Vecs
  are set directly to control cosine, so the test isolates the gate: a vector-near
  but lexically-unrelated pair is EXCLUDED (cosine alone is not enough), a distant
  pair is excluded, a cross-scope pair is excluded, and an already-aliased pair is
  excluded.
  """
  use Swarm.GraphCase, async: false

  alias Swarm.EntityResolution.Candidates
  alias Swarm.Graph.Store
  alias Swarm.Repo

  defp dim, do: Swarm.Config.embedding_dim()

  # A unit vector with 1.0 at index `i` (so identical i ⇒ cosine 1, distinct ⇒ 0).
  defp unit(i), do: List.duplicate(0.0, dim()) |> List.replace_at(i, 1.0)

  defp entity(key, vec, scope \\ "public") do
    id = Store.upsert_node("entity", key, scope: scope)
    Repo.query!("UPDATE node SET vec = $2 WHERE id = $1", [id, Pgvector.new(vec)])
    id
  end

  defp keys(pairs) do
    pairs |> Enum.map(fn p -> Enum.sort([p.a_key, p.b_key]) end) |> Enum.sort()
  end

  describe "propose/1 — two-signal hard gate" do
    test "proposes a near-dup pair (high cosine AND shared token), excludes the rest" do
      entity("Apollo Program", unit(0))
      entity("Project Apollo", unit(0))
      # vector-near (cosine 1) but NO shared token → must be EXCLUDED by the lex gate
      entity("Banana Bread", unit(0))
      # distant vector → excluded by the cosine gate
      entity("Quarterly Report", unit(1))
      # cross-scope (same key family, high cosine) → never proposed across scopes
      entity("Apollo Capsule", unit(0), "group")

      pairs = Candidates.propose(vec_threshold: 0.85, lex_threshold: 0.2)

      assert keys(pairs) == [["Apollo Program", "Project Apollo"]]
      [p] = pairs
      assert_in_delta p.cosine, 1.0, 0.001
      assert p.lex > 0.2
    end

    test "an already-aliased pair is excluded (defensive)" do
      a = entity("AllMusic", unit(0))
      b = entity("Allmusic", unit(0))

      Repo.query!(
        "INSERT INTO node_alias (type, alias_key, canonical_key) VALUES ('entity', 'Allmusic', 'AllMusic')"
      )

      assert Candidates.propose(vec_threshold: 0.85, lex_threshold: 0.2) == []
      _ = {a, b}
    end

    test "respects the vec threshold (a moderately-near pair below it is not proposed)" do
      entity("Apollo Program", unit(0))
      entity("Project Apollo", unit(1))

      # cosine is ~0 here → below any sane threshold → no proposal despite shared token
      assert Candidates.propose(vec_threshold: 0.85, lex_threshold: 0.2) == []
    end
  end
end
