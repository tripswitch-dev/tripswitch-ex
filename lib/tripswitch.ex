defmodule Tripswitch do
  @moduledoc """
  Official Elixir SDK for Tripswitch — a circuit breaker management service.

  ## Quick start

      {:ok, _pid} =
        Tripswitch.Client.start_link(
          project_id: "proj_...",
          api_key: "eb_pk_...",
          ingest_secret: "...",
          name: MyApp.Tripswitch
        )

      result =
        Tripswitch.execute(MyApp.Tripswitch, fn -> call_downstream() end,
          breakers: ["payment-service"],
          router: "router-id",
          metrics: %{"latency_ms" => :latency},
          tags: %{"region" => "us-east-1"}
        )

  ## Options for `execute/3`

  - `:breakers` — list of breaker names to check before running the task
  - `:router` — router ID to tag samples with
  - `:metrics` — `%{"name" => :latency | number | (result -> number)}`; one sample per entry
  - `:deferred_metrics` — `(result -> %{"name" => number})`; merged with `:metrics`
  - `:tags` — `%{String.t() => String.t()}` merged into every sample
  - `:error_evaluator` — `(result -> boolean)`; returns `true` when result should be counted as a
    failure. Defaults to matching `{:error, _}` tuples.
  - `:trace_id` — string propagated on every sample
  - `:breaker_selector` — `([breaker_meta] -> [name])` — dynamic breaker selection from metadata
  - `:router_selector` — `([router_meta] -> router_id)` — dynamic router selection from metadata
  """

  @contract_version "0.2"

  alias Tripswitch.{Flusher, StateServer}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns the SDK contract version this library implements.
  """
  @spec contract_version() :: String.t()
  def contract_version, do: @contract_version

  @doc """
  Executes `task`, checking the configured breakers before running.

  Returns the task's return value on success, or `{:error, :breaker_open}` if a
  breaker is open (or probabilistically blocks a half-open call). Exceptions are
  caught, counted as failures, and reraised after samples are flushed.

  See module docs for full option reference.
  """
  @spec execute(client_name :: atom(), task :: (-> result), opts :: keyword()) ::
          result | {:error, :breaker_open}
        when result: term()
  def execute(client, task, opts \\ []) when is_function(task, 0) do
    names = resolve_breaker_names(client, opts)

    case check_gate(client, names) do
      :blocked ->
        {:error, :breaker_open}

      :allowed ->
        run_and_report(client, task, opts)
    end
  end

  @doc """
  Enqueues a single sample for the given client.

  Useful when you want to report metrics outside of `execute/3`.

  ## Fields

  - `:router_id` — (required) router the sample belongs to
  - `:metric` — metric name string
  - `:value` — numeric value
  - `:ok` — `true` if the call succeeded
  - `:trace_id` — optional trace propagation string
  - `:tags` — optional `%{String.t() => String.t()}`
  """
  @spec report(atom(), map()) :: :ok
  def report(client, sample) when is_map(sample) do
    Flusher.enqueue(client, sample)
  end

  @doc """
  Returns the current state for a single breaker, or `nil` if not yet known.

  ## Return shape

      %{name: "breaker-name", state: "open" | "closed" | "half_open", allow_rate: float()}
  """
  @spec get_state(atom(), String.t()) :: map() | nil
  def get_state(client, breaker_name) do
    StateServer.get_state(client, breaker_name)
  end

  @doc """
  Returns all known breaker states as a map keyed by breaker name.
  """
  @spec get_all_states(atom()) :: %{String.t() => map()}
  def get_all_states(client) do
    StateServer.get_all_states(client)
  end

  @doc """
  Returns a merged diagnostics map combining stats from the SSE listener, flusher,
  and in-memory state.

  Useful for health checks and observability.
  """
  @spec stats(atom()) :: map()
  def stats(client) do
    Map.merge(StateServer.stats(client), Flusher.stats(client))
  end

  @doc """
  Returns cached breaker metadata fetched by the background sync process.

  Each entry is a map with `:id`, `:name`, and `:metadata` keys.
  Returns an empty list until the first metadata sync completes.
  """
  @spec get_breakers_metadata(atom()) :: list(map())
  def get_breakers_metadata(client) do
    StateServer.get_breakers_meta(client)
  end

  @doc """
  Returns cached router metadata fetched by the background sync process.

  Each entry is a map with `:id`, `:name`, and `:metadata` keys.
  Returns an empty list until the first metadata sync completes.
  """
  @spec get_routers_metadata(atom()) :: list(map())
  def get_routers_metadata(client) do
    StateServer.get_routers_meta(client)
  end

  @doc """
  Returns `true` if the named breaker is currently open, `false` otherwise.

  A half-open breaker returns `false` — use `execute/3` for probabilistic
  half-open enforcement.
  """
  @spec breaker_open?(atom(), String.t()) :: boolean()
  def breaker_open?(client, breaker_name) do
    StateServer.check_breakers(client, [breaker_name]) == :open
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp resolve_breaker_names(client, opts) do
    cond do
      names = opts[:breakers] ->
        names

      selector = opts[:breaker_selector] ->
        client |> StateServer.get_breakers_meta() |> selector.()

      true ->
        []
    end
  end

  defp resolve_router_id(client, opts) do
    cond do
      router = opts[:router] -> router
      selector = opts[:router_selector] -> client |> StateServer.get_routers_meta() |> selector.()
      true -> nil
    end
  end

  defp check_gate(_client, []), do: :allowed

  defp check_gate(client, names) do
    case StateServer.check_breakers(client, names) do
      :open -> :blocked
      {:half_open, rate} -> if :rand.uniform() < rate, do: :allowed, else: :blocked
      :closed -> :allowed
    end
  end

  defp run_and_report(client, task, opts) do
    start_ms = System.monotonic_time(:millisecond)

    {result, ok?, maybe_exception} = execute_task(task, opts[:error_evaluator])

    elapsed_ms = System.monotonic_time(:millisecond) - start_ms

    metrics = build_metrics(opts, result, elapsed_ms)

    if metrics != [] do
      router_id = resolve_router_id(client, opts)
      trace_id = opts[:trace_id]
      tags = opts[:tags] || %{}

      Enum.each(metrics, fn {name, value} ->
        Flusher.enqueue(client, %{
          router_id: router_id,
          metric: name,
          value: value * 1.0,
          ok: ok?,
          trace_id: trace_id,
          tags: tags
        })
      end)
    end

    case maybe_exception do
      nil -> result
      {exception, stacktrace} -> reraise exception, stacktrace
    end
  end

  defp execute_task(task, error_evaluator) do
    evaluator = error_evaluator || (&default_error?/1)

    try do
      result = task.()
      {result, not evaluator.(result), nil}
    rescue
      e -> {nil, false, {e, __STACKTRACE__}}
    end
  end

  defp build_metrics(opts, result, elapsed_ms) do
    base =
      (opts[:metrics] || %{})
      |> Enum.flat_map(fn
        {name, :latency} -> [{name, elapsed_ms}]
        {name, f} when is_function(f, 1) -> [{name, f.(result)}]
        {name, v} when is_number(v) -> [{name, v}]
        _ -> []
      end)

    deferred =
      case opts[:deferred_metrics] do
        nil -> []
        f when is_function(f, 1) -> f.(result) |> Enum.to_list()
      end

    base ++ deferred
  end

  defp default_error?({:error, _}), do: true
  defp default_error?(_), do: false
end
