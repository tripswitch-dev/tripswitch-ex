# tripswitch-ex

[![CI](https://github.com/tripswitch-dev/tripswitch-ex/actions/workflows/ci.yml/badge.svg)](https://github.com/tripswitch-dev/tripswitch-ex/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/tripswitch_ex.svg)](https://hex.pm/packages/tripswitch_ex)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

Official Elixir SDK for [Tripswitch](https://tripswitch.dev) — a circuit breaker management service.

This SDK conforms to the [Tripswitch SDK Contract v0.2](https://tripswitch.dev/docs/sdk-contract).

## Features

- **Real-time state sync** via Server-Sent Events (SSE)
- **Automatic sample reporting** with buffered, batched uploads
- **Fail-open by default** — your app stays available even if Tripswitch is unreachable
- **OTP-native** — supervised GenServer tree, safe for concurrent use
- **Graceful shutdown** — `terminate/2` flushes buffered samples before the process exits

## Installation

Add `:tripswitch_ex` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:tripswitch_ex, "~> 0.2"}
  ]
end
```

**Requires Elixir ~> 1.17 and Erlang/OTP ~> 26.**

## Authentication

Tripswitch uses a two-tier authentication model.

### Runtime credentials (SDK)

For SDK initialization, you need two credentials from **Project Settings → SDK Keys**:

| Credential | Prefix | Purpose |
|------------|--------|---------|
| **Project Key** | `eb_pk_` | SSE connection and state reads |
| **Ingest Secret** | 64-char hex | HMAC-signed sample ingestion |

### Admin credentials (management API)

For management and automation tasks, use an **Admin Key** from **Organization Settings → Admin Keys**:

| Credential | Prefix | Purpose |
|------------|--------|---------|
| **Admin Key** | `eb_admin_` | Org-scoped management operations |

Admin keys are used with the [Admin client](#admin-client) only — not for runtime SDK usage.

## Quick Start

Start the client under your application's supervision tree:

```elixir
# lib/my_app/application.ex
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Tripswitch.Client,
       project_id: System.fetch_env!("TRIPSWITCH_PROJECT_ID"),
       api_key: System.fetch_env!("TRIPSWITCH_API_KEY"),
       ingest_secret: System.fetch_env!("TRIPSWITCH_INGEST_SECRET"),
       name: MyApp.Tripswitch,
       on_state_change: &MyApp.Breakers.on_change/3}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

Then wrap operations with `Tripswitch.execute/3`:

```elixir
result =
  Tripswitch.execute(MyApp.Tripswitch, fn -> call_payment_api() end,
    breakers: ["payment-service"],
    router: "checkout-router",
    metrics: %{"latency_ms" => :latency},
    tags: %{"region" => "us-east-1"}
  )

case result do
  {:error, :breaker_open} ->
    # Circuit is open — return a cached or degraded response
    {:ok, cached_response()}

  {:error, reason} ->
    # The task itself returned an error
    {:error, reason}

  response ->
    # Task succeeded
    {:ok, response}
end
```

## Client Options

Pass these as keyword arguments to `Tripswitch.Client.start_link/1` (or inline in a supervision spec):

| Option | Description | Default |
|--------|-------------|---------|
| `:project_id` | Project ID — **required** | — |
| `:api_key` | Project key (`eb_pk_`) for SSE authentication | `nil` |
| `:ingest_secret` | 64-char hex secret for HMAC-signed sample reporting | `nil` |
| `:name` | Atom used to identify this client instance | `Tripswitch.Client` |
| `:fail_open` | Allow traffic when Tripswitch is unreachable | `true` |
| `:base_url` | Override the API endpoint | `https://api.tripswitch.dev` |
| `:on_state_change` | `(name, from_state, to_state -> any)` callback on breaker transitions | `nil` |
| `:global_tags` | `%{String.t() => String.t()}` merged into every sample | `%{}` |
| `:meta_sync_ms` | Metadata refresh interval in milliseconds. Set to `0` to disable. | `30_000` |

### State change callback

```elixir
Tripswitch.Client.start_link(
  project_id: "proj_...",
  api_key: "eb_pk_...",
  name: MyApp.Tripswitch,
  on_state_change: fn name, from, to ->
    Logger.warning("breaker #{name}: #{from} → #{to}")
    MyApp.Metrics.increment("tripswitch.transition", tags: [breaker: name, to: to])
  end
)
```

## `execute/3`

```elixir
Tripswitch.execute(client, task, opts \\ [])
```

Checks breaker state, runs `task`, and reports samples — all in one call. Returns the task's return value directly, or `{:error, :breaker_open}` if gated.

Exceptions inside `task` are caught, counted as failures, and reraised after samples are flushed.

### Options

| Option | Description |
|--------|-------------|
| `:breakers` | List of breaker names to check before executing |
| `:breaker_selector` | `([breaker_meta] -> [name])` — dynamically select breakers from cached metadata |
| `:router` | Router ID for sample reporting |
| `:router_selector` | `([router_meta] -> router_id)` — dynamically select a router from cached metadata |
| `:metrics` | `%{"name" => :latency \| number \| (result -> number)}` |
| `:deferred_metrics` | `(result -> %{"name" => number})` — extract metrics from the task result |
| `:error_evaluator` | `(result -> boolean)` — return `true` if the result is a failure. Defaults to matching `{:error, _}` tuples. |
| `:trace_id` | String propagated on every sample |
| `:tags` | `%{String.t() => String.t()}` merged into every sample for this call |

### Error classification

Every sample includes an `ok` field indicating success or failure. By default, `{:error, _}` tuples are failures and everything else is success. Exceptions are always failures.

Override with `:error_evaluator`:

```elixir
# Only count HTTP 5xx as failures; 4xx are expected
Tripswitch.execute(client, fn -> api_call() end,
  error_evaluator: fn
    {:error, %{status: s}} when s >= 500 -> true
    {:error, _} -> false
    _ -> false
  end
)
```

### Metrics

```elixir
Tripswitch.execute(client, fn -> downstream() end,
  router: "my-router",
  metrics: %{
    # Auto-computed task duration in milliseconds
    "latency_ms" => :latency,

    # Static numeric value
    "batch_size" => 128,

    # Computed from the task result
    "response_bytes" => fn {:ok, body} -> byte_size(body) end
  }
)
```

Use `:deferred_metrics` when the interesting values come from the result — for example, token counts from an LLM response:

```elixir
Tripswitch.execute(client, fn -> Anthropic.complete(prompt) end,
  breakers: ["anthropic-spend"],
  router: "llm-router",
  metrics: %{"latency_ms" => :latency},
  deferred_metrics: fn {:ok, response} ->
    %{
      "prompt_tokens" => response.usage.prompt_tokens,
      "completion_tokens" => response.usage.completion_tokens
    }
  end
)
```

### Dynamic selection

Use `:breaker_selector` and `:router_selector` to choose at runtime based on cached metadata:

```elixir
# Gate on breakers matching a metadata property
Tripswitch.execute(client, fn -> task() end,
  breaker_selector: fn breakers ->
    breakers
    |> Enum.filter(&(&1["metadata"]["region"] == "us-east-1"))
    |> Enum.map(& &1["name"])
  end
)

# Route to a router matching a metadata property
Tripswitch.execute(client, fn -> task() end,
  router_selector: fn routers ->
    case Enum.find(routers, &(&1["metadata"]["env"] == "production")) do
      nil -> nil
      router -> router["id"]
    end
  end,
  metrics: %{"latency_ms" => :latency}
)
```

**Constraints:**
- `:breakers` and `:breaker_selector` are mutually exclusive — using both raises `ArgumentError`
- `:router` and `:router_selector` are mutually exclusive — using both raises `ArgumentError`
- If the metadata cache hasn't been populated yet, `execute/3` returns `{:error, :metadata_unavailable}`
- If a selector returns an empty list or `nil`, no gating or sample emission occurs

## Trace IDs

Pass `:trace_id` on any `execute/3` call to associate the sample with a distributed trace:

```elixir
Tripswitch.execute(client, fn -> downstream_call() end,
  router: "my-router",
  trace_id: MyApp.Tracer.current_trace_id()
)
```

The trace ID is a plain string — use whatever format your tracing system produces (e.g., OpenTelemetry W3C trace IDs, Datadog `x-datadog-trace-id`, etc.).

## Other runtime functions

```elixir
# Send a sample directly (for async workflows or fire-and-forget reporting)
Tripswitch.report(client, %{
  router_id: "my-router",
  metric: "queue_depth",
  value: 42.0,
  ok: true,
  tags: %{"worker" => "processor-1"}
})

# Inspect a single breaker's current state (returns nil if not yet known)
%{name: name, state: state, allow_rate: rate} =
  Tripswitch.get_state(client, "payment-service")

# All known states as a map keyed by breaker name
all = Tripswitch.get_all_states(client)

# Convenience predicate (true only for fully open, not half-open)
if Tripswitch.breaker_open?(client, "payment-service") do
  serve_cached_response()
end

# SDK health diagnostics
stats = Tripswitch.stats(client)
# %{
#   sse_connected: true,
#   sse_reconnects: 0,
#   last_sse_event: ~U[2024-01-15 12:00:00Z],
#   cached_breakers: 4,
#   buffer_size: 0,
#   dropped_samples: 0,
#   flush_failures: 0,
#   last_successful_flush: ~U[2024-01-15 12:00:00Z]
# }
```

## Circuit breaker states

| State | Behavior |
|-------|----------|
| `"closed"` | All requests allowed, results reported |
| `"open"` | All requests return `{:error, :breaker_open}` immediately |
| `"half_open"` | Requests probabilistically allowed based on `allow_rate` (e.g., `0.2` = 20% allowed) |

## How it works

1. **State sync** — The client opens an SSE connection to Tripswitch and keeps a local cache of breaker states, updated in real time. No network call is made on each `execute/3`.
2. **Gate check** — Before running `task`, the SDK checks the local cache. Open breakers block immediately; half-open breakers use a local random draw against `allow_rate`.
3. **Sample reporting** — Results are buffered and flushed in batches of up to 500 samples (or every 15 seconds). Batches are gzip-compressed and HMAC-signed.
4. **Graceful degradation** — If Tripswitch is unreachable, the client fails open by default (unknown breaker state = closed). Samples are retried up to 3 times with backoff before being dropped.
5. **Clean shutdown** — When the OTP supervisor stops the client, `terminate/2` flushes any buffered samples synchronously before the process exits.

## Admin client

`Tripswitch.Admin` is a stateless client for management and automation. It does not require a running supervision tree.

```elixir
client = Tripswitch.Admin.new(api_key: "eb_admin_...")

# Projects
{:ok, projects} = Tripswitch.Admin.list_projects(client)
{:ok, project}  = Tripswitch.Admin.get_project(client, "proj_abc123")
{:ok, project}  = Tripswitch.Admin.create_project(client, %{workspace_id: "ws_...", name: "prod-payments"})
{:ok, project}  = Tripswitch.Admin.update_project(client, "proj_abc123", %{name: "prod-payments-v2"})

# delete_project requires confirm_name: to prevent accidental deletion
:ok = Tripswitch.Admin.delete_project(client, "proj_abc123", confirm_name: "prod-payments")

# Breakers
{:ok, breakers} = Tripswitch.Admin.list_breakers(client, "proj_abc123")
{:ok, breaker}  = Tripswitch.Admin.create_breaker(client, "proj_abc123", %{
  name: "api-latency",
  metric: "latency_ms",
  kind: "p95",
  op: "gt",
  threshold: 500.0
})
{:ok, states}   = Tripswitch.Admin.batch_get_breaker_states(client, "proj_abc123", %{
  router_id: "router_..."
})

# Routers
{:ok, routers} = Tripswitch.Admin.list_routers(client, "proj_abc123")
:ok = Tripswitch.Admin.link_breaker(client, "proj_abc123", "router_...", "breaker_...")
:ok = Tripswitch.Admin.unlink_breaker(client, "proj_abc123", "router_...", "breaker_...")

# Events
{:ok, %{events: events, next_cursor: cursor}} =
  Tripswitch.Admin.list_events(client, "proj_abc123", limit: 50)

# Project keys
{:ok, result} = Tripswitch.Admin.create_project_key(client, "proj_abc123", %{name: "ci-key"})
# result["key"] contains the full eb_pk_... value — store it, it won't be shown again
```

### Error handling

All admin functions return `{:ok, result}` or `{:error, %Tripswitch.Admin.Error{}}`. Transport failures return `{:error, exception}`.

```elixir
case Tripswitch.Admin.get_breaker(client, project_id, breaker_id) do
  {:ok, breaker} ->
    breaker

  {:error, %Tripswitch.Admin.Error{} = err} ->
    if Tripswitch.Admin.Error.not_found?(err) do
      nil
    else
      raise "unexpected error: #{err.message} (status #{err.status})"
    end

  {:error, reason} ->
    raise "transport error: #{inspect(reason)}"
end
```

Available predicates on `Tripswitch.Admin.Error`:

| Function | Status |
|----------|--------|
| `not_found?/1` | 404 |
| `unauthorized?/1` | 401 |
| `forbidden?/1` | 403 |
| `unprocessable?/1` | 422 |
| `rate_limited?/1` | 429 |
| `server_error?/1` | 5xx |

## Contributing

Contributions are welcome — please open an issue or pull request on [GitHub](https://github.com/tripswitch-dev/tripswitch-ex).

## License

[Apache License 2.0](LICENSE)
