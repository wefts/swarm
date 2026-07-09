defmodule Swarm.Graph.Aggregation do
  @moduledoc """
  Entity-centric knowledge aggregation — the "what/who is X" synthesis layer
  (STEP 2). Generalizes STEP 1's flat claim-aware answering: instead of surfacing
  loose `subject predicate object` facts, it gathers everything the claim graph
  asserts about the query's entities, **grouped by canonical predicate** and ranked
  by **corroboration** (how many distinct origins assert each fact), then hands that
  structured, provenance-tagged profile to the consilium to compose the answer.

  Council-shaped (codex + gemini-3.1-pro, 2026-06-30):
  - **Present, don't auto-resolve.** Multiple objects under one predicate are listed
    (with their source counts); the consilium — which has the question — decides
    enumeration vs conflict. No mechanical contradiction label; bi-temporal supersede
    is DEFERRED (the corpus's multi-object predicates are enumerations, not conflicts,
    and there is no predicate-cardinality to know otherwise).
  - **Bounded per predicate** (`#{5}` objects) and per entity, with an explicit
    `[+N more]` marker, so a hub entity can't starve the profile or fake exhaustiveness.
  - **Scope-enforced before aggregation** (the corroboration query's discipline): the
    edge's own `visibility_scope` AND both endpoint node scopes must be in the asker's
    scopes; refuted (`reward < 0`) and structural relations excluded; counts computed
    only over visible rows. Origin strings are never emitted (only the count) — a
    source identity must not leak.

  `entity_profile/3` returns the grouped profile + a flat fact list (for citations) +
  a `claim_support` signal the calibrator uses so a claim-grounded answer is not
  crushed by weak/absent chunk relevance.
  """

  alias Swarm.Graph.Corroboration
  alias Swarm.Repo

  require Logger

  @max_objects_per_predicate 5
  @max_predicates_per_entity 12
  @max_entities 8
  # Bounds the RESULT rows (≤ max_objects_per_predicate per predicate after the
  # window cap), generously above any real matched-entity set; the per-predicate
  # `omitted` stays accurate via the window total regardless of this cap.
  @row_limit 1000
  @min_term_len 3
  @stopwords ~w(the a an of to and or for with about how what which why who when
                where is are was were do does did can could should would related
                show find list recent get see me my our your this that these those)

  @type fact :: %{
          subject: String.t(),
          predicate: String.t(),
          object: String.t(),
          reliability: float(),
          corroboration: non_neg_integer()
        }
  @type object_ref :: %{
          object: String.t(),
          reliability: float(),
          corroboration: non_neg_integer()
        }
  @type group :: %{
          subject: String.t(),
          predicate: String.t(),
          objects: [object_ref()],
          omitted: non_neg_integer()
        }
  @type profile :: %{groups: [group()], facts: [fact()], claim_support: float() | nil}

  @empty %{groups: [], facts: [], claim_support: nil}

  @doc """
  Aggregate the claim graph about the entities named in `query`, visible to
  `scopes` (default-deny — empty ⇒ empty profile). Returns a `profile()`.
  """
  @spec entity_profile(String.t(), [String.t()], keyword()) :: profile()
  def entity_profile(query, scopes, opts \\ [])

  def entity_profile(_query, [], _opts), do: @empty

  def entity_profile(query, scopes, opts) when is_binary(query) and is_list(scopes) do
    case patterns(query) do
      [] -> @empty
      pats -> build(rows(scopes, pats), opts)
    end
  end

  @doc "Render the grouped profile as consilium grounding; `\"\"` if empty."
  @spec to_grounding(profile()) :: String.t()
  def to_grounding(%{groups: []}), do: ""

  def to_grounding(%{groups: groups}) do
    header =
      "Known facts about the entities in your question (extracted claims from the " <>
        "knowledge graph — derived facts, not primary text; the count is how many " <>
        "independent sources assert each):"

    body =
      groups
      |> Enum.group_by(& &1.subject)
      |> Enum.map_join("\n\n", fn {subject, subj_groups} ->
        lines = Enum.map_join(subj_groups, "\n", &group_line/1)
        "## #{subject}\n#{lines}"
      end)

    header <> "\n" <> body
  end

  defp group_line(%{predicate: pred, objects: objs, omitted: omitted}) do
    rendered = Enum.map_join(objs, "; ", fn o -> "#{o.object} [#{o.corroboration} source(s)]" end)
    extra = if omitted > 0, do: " [+#{omitted} more]", else: ""
    "- #{pred}: #{rendered}#{extra}"
  end

  # --- gather + group ---------------------------------------------------------

  @spec rows([String.t()], [String.t()]) :: [list()]
  defp rows(scopes, pats) do
    # Canonicalize the predicate IN SQL (downcase + collapse _/space) — primarily
    # DISPLAY normalization for the consilium (`public_ip` → "public ip"), since the
    # contract already constrains relation types to lowercase identifiers; it also
    # defensively MERGES origins should that ever loosen (code review). Window
    # functions give the top-K objects per predicate AND the TRUE per-predicate total,
    # so `omitted` is accurate even when the overall row cap truncates (the cap bounds
    # the result, not the count — the hub-starves-the-profile bug).
    %{rows: rows} =
      Repo.query!(
        """
        WITH visible AS (
          SELECT s.key AS subject,
                 btrim(lower(regexp_replace(e.type, '[[:space:]_]+', ' ', 'g'))) AS predicate,
                 o.key AS object,
                 max(e.reliability) AS reliability,
                 count(DISTINCT coalesce(ep.lineage, ep.origin, ep.provenance)) AS corroboration
            FROM edge e
            JOIN node s ON s.id = e.src AND s.scope = ANY($1::text[])
            JOIN node o ON o.id = e.dst AND o.scope = ANY($1::text[])
            LEFT JOIN edge_provenance ep ON ep.edge_id = e.id
           WHERE e.evidence_kind = 'claim'
             AND e.visibility_scope = ANY($1::text[])
             AND e.reward >= 0
             AND e.type <> ALL($2::text[])
             AND s.key ILIKE ANY($3)
           GROUP BY s.key, btrim(lower(regexp_replace(e.type, '[[:space:]_]+', ' ', 'g'))), o.key
        ),
        ranked AS (
          SELECT subject, predicate, object, reliability, corroboration,
                 row_number() OVER w AS rn,
                 count(*) OVER (PARTITION BY subject, predicate) AS pred_total
            FROM visible
          WINDOW w AS (PARTITION BY subject, predicate
                       ORDER BY corroboration DESC, reliability DESC, object)
        )
        SELECT subject, predicate, object, reliability, corroboration, pred_total
          FROM ranked
         WHERE rn <= $4
         ORDER BY subject, predicate, rn
         LIMIT $5
        """,
        [
          scopes,
          Corroboration.structural_relations(),
          pats,
          @max_objects_per_predicate,
          @row_limit
        ]
      )

    rows
  rescue
    # Best-effort augmentation: a transport blip must not raise out of the turn
    # (the T6 algebra). Retrieval has already succeeded; degrade to no profile.
    e in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "aggregation: gather failed, degrading to no facts (#{Exception.message(e)})"
      )

      []
  end

  @spec build([list()], keyword()) :: profile()
  defp build([], _opts), do: @empty

  defp build(rows, _opts) do
    # SQL already canonicalized the predicate, capped objects to the top-K per
    # predicate (rn ≤ @max_objects_per_predicate) in corroboration order, and carries
    # the TRUE per-predicate total for an accurate `omitted`.
    pred_groups =
      rows
      |> Enum.group_by(
        fn [subj, pred, _o, _r, _c, _t] -> {subj, pred} end,
        fn [_s, _p, obj, rel, corr, total] ->
          %{object: obj, reliability: rel, corroboration: corr, pred_total: total}
        end
      )
      |> Enum.map(fn {{subject, predicate}, objs} ->
        best = hd(objs)

        %{
          subject: subject,
          predicate: predicate,
          objects: Enum.map(objs, &Map.take(&1, [:object, :reliability, :corroboration])),
          omitted: max(best.pred_total - length(objs), 0),
          rank: {best.corroboration, best.reliability}
        }
      end)

    # Bound a hub: strongest entities, and within each the strongest predicate-groups
    # (by their best fact), so one dense node can't crowd or fake-exhaust the profile.
    groups =
      pred_groups
      |> Enum.group_by(& &1.subject)
      |> Enum.sort_by(fn {_s, gs} -> gs |> Enum.map(& &1.rank) |> Enum.max() end, :desc)
      |> Enum.take(@max_entities)
      |> Enum.flat_map(fn {_s, gs} ->
        gs |> Enum.sort_by(& &1.rank, :desc) |> Enum.take(@max_predicates_per_entity)
      end)
      |> Enum.map(&Map.delete(&1, :rank))

    facts =
      for g <- groups, o <- g.objects do
        %{
          subject: g.subject,
          predicate: g.predicate,
          object: o.object,
          reliability: o.reliability,
          corroboration: o.corroboration
        }
      end

    # nil (not 0.0) when there are NO facts — so the calibrator distinguishes
    # "no claim grounding" (no cap) from "weak claim grounding" (capped) — code review.
    claim_support =
      case facts do
        [] -> nil
        _ -> facts |> Enum.map(& &1.reliability) |> Enum.max()
      end

    %{groups: groups, facts: facts, claim_support: claim_support}
  end

  @spec patterns(String.t()) :: [String.t()]
  defp patterns(query) do
    query
    |> String.downcase()
    |> String.split(~r/\W+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < @min_term_len or &1 in @stopwords))
    |> Enum.uniq()
    |> Enum.map(&"%#{&1}%")
  end
end
