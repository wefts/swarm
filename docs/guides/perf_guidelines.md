# Performance Guidelines — write it fast the FIRST time

Compact and prescriptive. **Include this file verbatim in any prompt that
delegates code to a model**, and apply it in review. Complexity shape is a
DESIGN decision made when the code is written — not an optimization deferred
until it hurts. Design for 10× today's data; today's n is the smallest this
system will ever be.

## The one rule

State (mentally or in the doc/`@spec`) the time AND memory shape of any function
that touches the graph or a corpus: O(?) in n nodes/edges/docs. If either is
quadratic, justify it or reshape it before writing the body.

## Graph traversal — the hot path

Traversal is the primary mode of thinking (Domain 1) and the spike showed it is
the axis that decides the engine. Treat it as load-bearing:

- **Bound depth and breadth.** Variable-length traversal without a depth cap and
  without a visited-set explodes (path enumeration is exponential). Cap depth;
  dedup nodes; aggregate confidence at the end, not per path.
- **Let the engine traverse.** Recursive CTE / native graph query — not a
  per-row fetch loop in app code. Decay (`exp(-lambda*age)`) and path-confidence
  aggregation happen inside the query.
- **Index what you filter.** Visibility-scope is an indexed label, not a per-edge
  predicate evaluated at query time (ADR-5).
- **Re-measure per engine.** Cosine thresholds and traversal cost are
  engine/model-specific; re-derive on change, never hardcode.

## Vectors — think in arrays, not elements

```text
WRONG: Python pair loop            RIGHT: vectorized
for i in range(n):                 sims = a @ b.T
    for j in range(n):             hits = np.argwhere(sims >= t)
        if sims[i,j] >= t: ...
```

- No `for` over array rows for math — matrix ops, boolean masks,
  `argwhere`/`argmax`/`argsort`, broadcasting.
- Never materialize O(n²) when consumed once: stream in row chunks, threshold
  per chunk.
- Exploit structure to skip work (cross-source only → block by source; never
  compute the within-source triangle).
- Normalize once outside the loop; `keepdims=True`; guard zero norms.
- Let the vector index do kNN (pgvector HNSW); tune `ef_search`, don't scan.

## Database — let the database do database work

- Filter/aggregate in SQL/Cypher (`WHERE`, `GROUP BY`, `COUNT`, `IN (...)`), not
  in app code after fetching everything.
- Many writes → one batched transaction, never N × single statement.
- A query that scans what it filters needs the index next to the schema.
- Atomic mutation (CAS, increment) in the engine, not read-modify-write in app
  code (lost updates under concurrency — ADR-1).

## Language fast/slow pairs

Python:

| Slow | Fast |
| --- | --- |
| `x in list` in a loop (O(n)) | `x in set` / dict (O(1)) |
| `for …: out.append(…)` | comprehension / generator |
| dedup via `if x not in out` | `dict.fromkeys(xs)` (ordered, O(n)) |
| `s += piece` in a loop | `"".join(pieces)` |
| `re.search(pat, …)` per call | precompiled `_PAT` at module top |
| `await` per item | batch (`embed(chunk)`) or `asyncio.gather` |

Elixir:

| Slow | Fast |
| --- | --- |
| `Enum` chain over a large collection | `Stream` (lazy) until the final reduce |
| `list ++ elem` / append in a loop | prepend then `Enum.reverse`, or build a map |
| `Enum.member?/2` on a list in a loop | `MapSet` membership (O(1) amortized) |
| Loading the whole graph into one process | query the engine; keep process state small |
| One DB call per item | batch / `Task.async_stream` for independent I/O |

## Declarative-first

Push logic into the engine built for it instead of reimplementing it in app
loops: traversal/joins/filters → the graph engine (SQL/Cypher); vector math →
numpy / the vector index; coordination → OTP; config thresholds → YAML. Code is
the glue, not the engine.

## Measure, don't argue

Anything beyond trivial gets a before/after number: wall time + peak allocation
on a realistic corpus AND a synthetic 10× run. Pattern: a bench script under
`tmp/scripts/` (or the spike harness), equivalence-asserted against the
reference implementation. A claim without a number is a guess — the eval/bench
harnesses exist precisely so nobody tunes blind.

## Review gate (for the integrator)

Before accepting code, ask: (1) what is the complexity shape and does it survive
10× the corpus? (2) does anything materialize O(n²) in time or memory? (3) is
there an app-code loop doing what the graph engine / numpy / SQL / OTP should do?
"Acceptable at today's n" is not acceptance.
