# Hubness diagnostic (relevance-floor + hubness campaign). Pulls every chunk vector
# into memory, embeds a mixed query set (in-scope + out-of-scope) via real bge-m3, and
# compares RAW cosine vs two hubness corrections — does any of them (a) separate
# in-scope from out-of-scope scores (→ a relevance floor becomes possible) and
# (b) de-rank the "magnet" chunks (→ better recall@1)?
#
#   SWARM_DB_NAME=swarm_slice SWARM_ML_ADDRESS=172.19.0.5:50051 \
#     MIX_ENV=dev mix run --no-start \
#     -r test/support/wikipedia_connector.ex test/support/diagnose_hubness.exs

require Logger
Logger.configure(level: :warning)

alias Swarm.ML.Embeddings
alias Swarm.Repo

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:grpc)
{:ok, _} = Repo.start_link()
{:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: GRPC.Client.Supervisor)

# --- load all chunk vectors (public scope only) ---
%{rows: rows} =
  Repo.query!("""
  SELECT c.id, n.key, c.text, c.vec
  FROM chunk c JOIN node n ON n.id = c.node_id
  WHERE n.scope = 'public' AND c.vec IS NOT NULL
  """)

chunks =
  Enum.map(rows, fn [id, key, text, vec] ->
    %{id: id, key: key, text: text, v: Pgvector.to_list(vec)}
  end)

dot = fn a, b -> a |> Enum.zip(b) |> Enum.reduce(0.0, fn {x, y}, s -> s + x * y end) end
norm = fn a -> :math.sqrt(dot.(a, a)) end
cos = fn a, b -> dot.(a, b) / (norm.(a) * norm.(b) + 1.0e-12) end

norms = Enum.map(chunks, &norm.(&1.v))
IO.puts("== Hubness diagnostic ==")
IO.puts("chunks: #{length(chunks)}")
IO.puts("vec norms: min #{Float.round(Enum.min(norms), 4)} max #{Float.round(Enum.max(norms), 4)} " <>
        "(≈1.0 ⇒ bge-m3 returns unit vectors)")

# --- query set: in-scope (from real chunk text) + out-of-scope ---
in_scope =
  chunks
  |> Enum.take_every(max(div(length(chunks), 8), 1))
  |> Enum.take(8)
  |> Enum.map(fn c -> {c.text |> String.split(~r/\s+/, trim: true) |> Enum.take(8) |> Enum.join(" "), c.key} end)

out_scope =
  [
    "how do I cook a risotto with mushrooms",
    "what is the capital of France",
    "summarize the plot of the movie Inception",
    "explain the BLERG-9000 quantum fusion reactor",
    "what is the boiling point of mercury",
    "best exercises for lower back pain",
    "who won the 2024 election",
    "recipe for chocolate chip cookies"
  ]
  |> Enum.map(&{&1, :none})

queries = in_scope ++ out_scope
{:ok, %{vectors: qvecs}} = Embeddings.embed(Enum.map(queries, fn {q, _} -> q end))
qset = Enum.zip(queries, qvecs) |> Enum.map(fn {{q, exp}, v} -> %{q: q, exp: exp, v: v} end)

# --- global mean chunk vector (for centering) ---
dim = length(hd(chunks).v)
sum = Enum.reduce(chunks, List.duplicate(0.0, dim), fn c, acc -> Enum.zip_with(acc, c.v, &+/2) end)
mean = Enum.map(sum, &(&1 / length(chunks)))
centered = Enum.map(chunks, fn c -> %{c | v: Enum.zip_with(c.v, mean, &-/2)} end)

# per-chunk hubness r_S(c): mean cosine to the query set (high ⇒ hub)
rs =
  Map.new(chunks, fn c ->
    {c.id, Enum.sum(Enum.map(qset, &cos.(&1.v, c.v))) / length(qset)}
  end)

topk = fn qv, cs, scorer, k ->
  cs
  |> Enum.map(fn c -> {c.key, c.id, scorer.(qv, c)} end)
  |> Enum.sort_by(fn {_, _, s} -> -s end)
  |> Enum.take(k)
end

raw = fn qv, c -> cos.(qv, c.v) end
cent = fn qv_centered, c -> cos.(qv_centered, c.v) end
csls = fn qv, c -> 2.0 * cos.(qv, c.v) - rs[c.id] end

# center a query against the same global mean
center_q = fn qv -> Enum.zip_with(qv, mean, &-/2) end

report = fn label, scorer, cs, qmap ->
  rank1 =
    Enum.map(qset, fn q ->
      [{_k, _id, s} | _] = topk.(qmap.(q.v), cs, scorer, 3)
      {q.exp, s}
    end)

  ins = rank1 |> Enum.reject(fn {e, _} -> e == :none end) |> Enum.map(&elem(&1, 1))
  outs = rank1 |> Enum.filter(fn {e, _} -> e == :none end) |> Enum.map(&elem(&1, 1))
  mn = fn l -> Float.round(Enum.sum(l) / length(l), 4) end

  IO.puts("\n-- #{label} --")
  IO.puts("rank-1 score  in-scope:  #{Enum.map(ins, &Float.round(&1, 3)) |> inspect}")
  IO.puts("rank-1 score  out-scope: #{Enum.map(outs, &Float.round(&1, 3)) |> inspect}")
  IO.puts("mean in-scope #{mn.(ins)}  vs  mean out-scope #{mn.(outs)}  (gap #{Float.round(mn.(ins) - mn.(outs), 4)})")
  sep = Enum.min(ins) > Enum.max(outs)
  IO.puts("SEPARABLE by a flat floor? #{sep}  (min in #{Float.round(Enum.min(ins),3)} vs max out #{Float.round(Enum.max(outs),3)})")
end

report.("RAW cosine", raw, chunks, fn v -> v end)
report.("CENTERED cosine (subtract global mean)", cent, centered, center_q)
report.("CSLS (2cos - r_S)", csls, chunks, fn v -> v end)

# --- hub frequency: which chunks dominate top-3 across ALL queries (raw vs csls) ---
hub_freq = fn scorer, cs, qmap ->
  qset
  |> Enum.flat_map(fn q -> topk.(qmap.(q.v), cs, scorer, 3) |> Enum.map(fn {k, _, _} -> k end) end)
  |> Enum.frequencies()
  |> Enum.sort_by(fn {_, n} -> -n end)
  |> Enum.take(5)
end

IO.puts("\n-- magnet chunks (appearances in top-3 across #{length(qset)} queries) --")
IO.puts("RAW : #{inspect(hub_freq.(raw, chunks, fn v -> v end))}")
IO.puts("CSLS: #{inspect(hub_freq.(csls, chunks, fn v -> v end))}")
