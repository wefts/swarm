defmodule Swarm.EntityResolution.Candidates do
  @moduledoc """
  Candidate proposal for entity-resolution soft-match (ER-2; the "Doubt" of the
  Embed–Doubt–Confirm pattern). Cheap, no LLM.

  A pair is proposed only when it clears a **two-signal hard gate** (decorrelated
  council): cosine alone over-proposes, and a false merge *contaminates* evidence
  (lets one entity's evidence corroborate another) — which origin accounting cannot
  undo. So a candidate needs an INDEPENDENT signal besides vectors:

  - same `(type, scope)` — cross-scope is never proposed (merge refuses it, and it
    would waste a confirm or risk a leak);
  - **vector** cosine over entity identity `node.vec` ≥ `vec_threshold` (recall);
  - **lexical** token-Jaccard of the two keys ≥ `lex_threshold` (the independent
    signal — they must share a significant surface token, not merely be "nearby").

  The LLM (ER-3) then ADJUDICATES these plausible candidates; it must never have to
  rescue a noisy pure-vector proposal. Already-folded pairs (standing alias table)
  are excluded; merged-away nodes are gone, so they cannot reappear.

  Scale note: the self-join is fine for a bounded entity set; at large scale switch
  to per-node HNSW kNN (the `vec` HNSW index exists). `max_pairs` bounds a pass.
  """

  alias Swarm.Repo

  @typedoc "A proposed pair: the two node ids/keys, their cosine, and their token-Jaccard."
  @type pair :: %{
          a: integer(),
          b: integer(),
          a_key: String.t(),
          b_key: String.t(),
          cosine: float(),
          lex: float()
        }

  @doc """
  Propose near-duplicate entity pairs that clear the two-signal gate, strongest
  cosine first. `opts`: `:vec_threshold`, `:lex_threshold`, `:limit` (override the
  configured tuning inventory).
  """
  @spec propose(keyword()) :: [pair()]
  def propose(opts \\ []) do
    cfg = Application.get_env(:swarm, :entity_resolution, [])
    vec_t = Keyword.get(opts, :vec_threshold) || cfg[:vec_threshold] || 0.85
    lex_t = Keyword.get(opts, :lex_threshold) || cfg[:lex_threshold] || 0.2
    limit = Keyword.get(opts, :limit) || cfg[:max_pairs] || 50

    # Vector gate + same (type, scope), strongest cosine first. `a.id < b.id` gives
    # each unordered pair once and excludes self-pairs. Already-aliased keys are
    # excluded (defensive — a merged node is deleted, so cannot rejoin).
    %{rows: rows} =
      Repo.query!(
        """
        SELECT a.id, a.key, b.id, b.key, 1 - (a.vec <=> b.vec) AS cosine
          FROM node a
          JOIN node b
            ON a.type = b.type AND a.scope = b.scope AND a.id < b.id
         WHERE a.type = 'entity' AND b.type = 'entity'
           AND a.vec IS NOT NULL AND b.vec IS NOT NULL
           AND 1 - (a.vec <=> b.vec) >= $1
           AND NOT EXISTS (
             SELECT 1 FROM node_alias x
              WHERE x.type = 'entity'
                AND ((x.alias_key = a.key AND x.canonical_key = b.key)
                  OR (x.alias_key = b.key AND x.canonical_key = a.key))
           )
         ORDER BY cosine DESC
         LIMIT $2
        """,
        [vec_t, limit]
      )

    rows
    |> Enum.map(fn [a, a_key, b, b_key, cosine] ->
      %{a: a, b: b, a_key: a_key, b_key: b_key, cosine: cosine, lex: token_jaccard(a_key, b_key)}
    end)
    # The independent lexical hard gate: a vector-near but lexically-unrelated pair
    # ("Apollo Program" vs an unrelated topic the embedder placed nearby) is dropped
    # here — the LLM never sees it.
    |> Enum.filter(fn p -> p.lex >= lex_t end)
  end

  # Jaccard over significant key tokens (NFC, lowercased, len ≥ 2, alphanumeric).
  # No lossy ASCII folding (keeps Cyrillic/CJK). 0.0 when either side has no tokens.
  @spec token_jaccard(String.t(), String.t()) :: float()
  defp token_jaccard(a, b) do
    ta = tokens(a)
    tb = tokens(b)

    if MapSet.size(ta) == 0 or MapSet.size(tb) == 0 do
      0.0
    else
      inter = MapSet.intersection(ta, tb) |> MapSet.size()
      union = MapSet.union(ta, tb) |> MapSet.size()
      inter / union
    end
  end

  @spec tokens(String.t()) :: MapSet.t()
  defp tokens(key) do
    key
    |> :unicode.characters_to_nfc_binary()
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 2))
    |> MapSet.new()
  end
end
