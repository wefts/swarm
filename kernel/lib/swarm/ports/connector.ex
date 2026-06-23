defmodule Swarm.Ports.Connector do
  @moduledoc """
  Connector port (Domain 2): an inbound adapter that turns an external source
  into normalized events on the bus.

  Behaviour only — concrete connectors (files, git, wiki, …) are adapters that
  live outside the kernel and are discovered at runtime. The kernel depends on
  this contract, never on an adapter.

  ## Two shapes (swarm ADR-5)

  - **`stream/1`** — a *full dump*: the connector yields every event lazily and
    the stream simply ends. Right for small/local, ceiling-free sources (files).
  - **`fetch/2`** — a *kernel-driven paginated pull*: the connector returns one
    page and the **next cursor**, and the kernel drives the loop to exhaustion.
    This is the contract for **hostile** sources (title-sorted + hard list limit +
    byte-ceiling + flaky partial fetch). Completeness is owned by the kernel loop,
    not by trusting a connector's top-N; a source-imposed ceiling is reported via
    `truncated: true` and **logged, never silently dropped**. Pulling one page at
    a time is the demand-driven backpressure that stops a hostile source flooding
    the graph.

  A connector implements **one** of the two (both are optional callbacks);
  `Swarm.Connector.Sync` prefers `fetch/2` when exported, else drives `stream/1`
  as a single exhaustive page. Either way events land via `Swarm.Ingest` — the
  graph, never a raw source payload, is what a model later reads.
  """

  @typedoc "A normalized ingest event. Shape is fixed by the Protobuf contract."
  @type event :: map()

  @typedoc "Opaque pagination cursor owned by the connector; `:start` begins, `:done` ends."
  @type cursor :: term()

  @typedoc """
  One page of a paginated pull. `events` are this page's events; `cursor` is the
  next cursor (or `:done` at exhaustion); `truncated?` is true iff the source
  imposed a ceiling on THIS page (the kernel logs it — no silent cap).
  """
  @type page :: %{events: [event()], cursor: cursor() | :done, truncated?: boolean()}

  @typedoc "Connector self-description for the registry (name, capabilities, health)."
  @type info :: map()

  @doc "Stream normalized events from the source into the kernel (full-dump shape)."
  @callback stream(opts :: keyword()) :: Enumerable.t()

  @doc """
  Fetch one page from `cursor` (`:start` to begin). The kernel calls this
  repeatedly until `cursor: :done`, owning completeness. For a delta sync the
  kernel passes `:since` (a watermark) in `opts`; the connector returns only
  events at/after it.
  """
  @callback fetch(cursor :: cursor(), opts :: keyword()) :: {:ok, page()} | {:error, term()}

  @doc "Report connector identity, capability, and health for the registry."
  @callback describe() :: info()

  @optional_callbacks stream: 1, fetch: 2
end
