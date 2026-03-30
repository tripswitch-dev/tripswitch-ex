defmodule Tripswitch.SSEListener do
  @moduledoc false

  # Maintains a persistent HTTP/1.1 SSE connection to the Tripswitch API and
  # pushes breaker state changes into StateServer. Uses Mint directly so we
  # can force HTTP/1.1 (required for SSE — HTTP/2 multiplexing interferes with
  # long-lived event streams).

  use GenServer
  require Logger

  alias Tripswitch.{Config, Naming, StateServer}

  @reconnect_delays [1_000, 2_000, 5_000, 10_000, 30_000]
  @connect_timeout 10_000

  defstruct [
    :config,
    :conn,
    :request_ref,
    buffer: "",
    reconnect_attempt: 0
  ]

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: Naming.sse_listener(config.name))
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(config) do
    state = %__MODULE__{config: config}

    if config.api_key do
      {:ok, state, {:continue, :connect}}
    else
      Logger.debug("[Tripswitch] No API key configured — SSE listener idle")
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:connect, state) do
    case open_connection(state.config) do
      {:ok, conn, request_ref} ->
        StateServer.set_sse_connected(state.config.name, true)
        {:noreply, %{state | conn: conn, request_ref: request_ref, reconnect_attempt: 0}}

      {:error, reason} ->
        Logger.warning("[Tripswitch] SSE connection failed: #{inspect(reason)}")
        {:noreply, schedule_reconnect(state)}
    end
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.HTTP.stream(conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        state = process_responses(responses, state)
        {:noreply, state}

      {:error, _conn, reason, _responses} ->
        Logger.warning("[Tripswitch] SSE stream error: #{inspect(reason)}")
        StateServer.increment_sse_reconnects(state.config.name)
        {:noreply, schedule_reconnect(%{state | conn: nil, request_ref: nil})}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp open_connection(config) do
    url = Config.sse_url(config)
    uri = URI.parse(url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    port = uri.port || if(scheme == :https, do: 443, else: 80)
    path = uri.path <> if(uri.query, do: "?#{uri.query}", else: "")

    transport_opts =
      if scheme == :https, do: [timeout: @connect_timeout], else: [timeout: @connect_timeout]

    with {:ok, conn} <-
           Mint.HTTP.connect(scheme, uri.host, port,
             protocols: [:http1],
             transport_opts: transport_opts
           ),
         {:ok, conn, request_ref} <-
           Mint.HTTP.request(conn, "GET", path, sse_headers(config), nil) do
      {:ok, conn, request_ref}
    end
  end

  defp sse_headers(config) do
    [
      {"authorization", "Bearer #{config.api_key}"},
      {"accept", "text/event-stream"},
      {"cache-control", "no-cache"}
    ]
  end

  defp process_responses(responses, state) do
    Enum.reduce(responses, state, fn response, acc ->
      case response do
        {:status, _ref, 200} ->
          acc

        {:status, _ref, status} ->
          Logger.error("[Tripswitch] SSE unexpected status #{status}, will reconnect")
          StateServer.increment_sse_reconnects(acc.config.name)
          schedule_reconnect(%{acc | conn: nil, request_ref: nil})

        {:headers, _ref, _headers} ->
          acc

        {:data, _ref, data} ->
          process_data(data, acc)

        {:done, _ref} ->
          Logger.debug("[Tripswitch] SSE stream ended, reconnecting")
          StateServer.increment_sse_reconnects(acc.config.name)
          schedule_reconnect(%{acc | conn: nil, request_ref: nil})

        {:error, _ref, reason} ->
          Logger.warning("[Tripswitch] SSE response error: #{inspect(reason)}")
          StateServer.increment_sse_reconnects(acc.config.name)
          schedule_reconnect(%{acc | conn: nil, request_ref: nil})
      end
    end)
  end

  defp process_data(data, state) do
    buffer = state.buffer <> data
    {events, remaining} = parse_events(buffer)

    Enum.each(events, fn event_json ->
      case Jason.decode(event_json) do
        {:ok, %{"breaker" => name, "state" => new_state} = event} ->
          allow_rate = Map.get(event, "allow_rate")

          if new_state == "half_open" && is_nil(allow_rate) do
            Logger.warning(
              "[Tripswitch] SSE half_open event missing allow_rate for breaker #{name}"
            )
          end

          StateServer.update_breaker(state.config.name, name, new_state, allow_rate)

        {:error, reason} ->
          Logger.error("[Tripswitch] Failed to parse SSE event: #{inspect(reason)}")
      end
    end)

    %{state | buffer: remaining}
  end

  # SSE events are separated by blank lines (\n\n).
  # Each event may have one or more "data: ..." lines.
  defp parse_events(buffer) do
    parts = String.split(buffer, "\n\n")

    case List.pop_at(parts, -1) do
      {remaining, complete_parts} ->
        events =
          for part <- complete_parts,
              String.trim(part) != "",
              line <- String.split(part, "\n"),
              String.starts_with?(line, "data: ") do
            String.slice(line, 6..-1//1)
          end

        {events, remaining}
    end
  end

  defp schedule_reconnect(state) do
    delay =
      Enum.at(@reconnect_delays, state.reconnect_attempt, List.last(@reconnect_delays))

    Process.send_after(self(), :reconnect, delay)
    %{state | reconnect_attempt: state.reconnect_attempt + 1}
  end
end
