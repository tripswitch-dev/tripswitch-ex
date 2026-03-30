defmodule Tripswitch.StateServer do
  @moduledoc false

  # Holds real-time breaker states (updated via SSE) and cached metadata
  # (breakers + routers, refreshed periodically by MetadataCache).

  use GenServer

  alias Tripswitch.Naming

  defstruct [
    :config,
    breaker_states: %{},
    breakers_meta: [],
    routers_meta: [],
    breakers_etag: nil,
    routers_etag: nil,
    sse_connected: false,
    sse_reconnects: 0,
    last_sse_event: nil
  ]

  # ---------------------------------------------------------------------------
  # Client API (called by SSEListener, MetadataCache, and Tripswitch public API)
  # ---------------------------------------------------------------------------

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: Naming.state_server(config.name))
  end

  def update_breaker(client_name, breaker_name, new_state, allow_rate) do
    GenServer.cast(
      Naming.state_server(client_name),
      {:update_breaker, breaker_name, new_state, allow_rate}
    )
  end

  def set_sse_connected(client_name, connected?) do
    GenServer.cast(Naming.state_server(client_name), {:set_sse_connected, connected?})
  end

  def increment_sse_reconnects(client_name) do
    GenServer.cast(Naming.state_server(client_name), :increment_sse_reconnects)
  end

  def update_metadata(client_name, type, items, etag) when type in [:breakers, :routers] do
    GenServer.cast(Naming.state_server(client_name), {:update_metadata, type, items, etag})
  end

  def get_state(client_name, breaker_name) do
    GenServer.call(Naming.state_server(client_name), {:get_state, breaker_name})
  end

  def get_all_states(client_name) do
    GenServer.call(Naming.state_server(client_name), :get_all_states)
  end

  def get_breakers_meta(client_name) do
    GenServer.call(Naming.state_server(client_name), :get_breakers_meta)
  end

  def get_routers_meta(client_name) do
    GenServer.call(Naming.state_server(client_name), :get_routers_meta)
  end

  def get_etag(client_name, type) when type in [:breakers, :routers] do
    GenServer.call(Naming.state_server(client_name), {:get_etag, type})
  end

  def stats(client_name) do
    GenServer.call(Naming.state_server(client_name), :stats)
  end

  # Check states for a list of breaker names. Returns :open, {:half_open, float}, or :closed.
  # Called directly from Execute — no GenServer hop for performance.
  def check_breakers(client_name, names) when is_list(names) do
    GenServer.call(Naming.state_server(client_name), {:check_breakers, names})
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(config) do
    {:ok, %__MODULE__{config: config}}
  end

  @impl true
  def handle_cast({:update_breaker, name, new_state, allow_rate}, state) do
    old_entry = Map.get(state.breaker_states, name)
    old_state = old_entry && old_entry.state

    rate = allow_rate || 0.0
    entry = %{state: new_state, allow_rate: rate}
    new_states = Map.put(state.breaker_states, name, entry)

    if old_state && old_state != new_state && state.config.on_state_change do
      state.config.on_state_change.(name, old_state, new_state)
    end

    {:noreply,
     %{
       state
       | breaker_states: new_states,
         sse_connected: true,
         last_sse_event: DateTime.utc_now()
     }}
  end

  def handle_cast({:set_sse_connected, connected?}, state) do
    {:noreply, %{state | sse_connected: connected?}}
  end

  def handle_cast(:increment_sse_reconnects, state) do
    {:noreply, %{state | sse_reconnects: state.sse_reconnects + 1, sse_connected: false}}
  end

  def handle_cast({:update_metadata, :breakers, items, etag}, state) do
    {:noreply, %{state | breakers_meta: items, breakers_etag: etag}}
  end

  def handle_cast({:update_metadata, :routers, items, etag}, state) do
    {:noreply, %{state | routers_meta: items, routers_etag: etag}}
  end

  @impl true
  def handle_call({:get_state, name}, _from, state) do
    result =
      case Map.get(state.breaker_states, name) do
        nil -> nil
        entry -> Map.put(entry, :name, name)
      end

    {:reply, result, state}
  end

  def handle_call(:get_all_states, _from, state) do
    all =
      Map.new(state.breaker_states, fn {name, entry} ->
        {name, Map.put(entry, :name, name)}
      end)

    {:reply, all, state}
  end

  def handle_call(:get_breakers_meta, _from, state) do
    {:reply, state.breakers_meta, state}
  end

  def handle_call(:get_routers_meta, _from, state) do
    {:reply, state.routers_meta, state}
  end

  def handle_call({:get_etag, :breakers}, _from, state) do
    {:reply, state.breakers_etag, state}
  end

  def handle_call({:get_etag, :routers}, _from, state) do
    {:reply, state.routers_etag, state}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      sse_connected: state.sse_connected,
      sse_reconnects: state.sse_reconnects,
      last_sse_event: state.last_sse_event,
      cached_breakers: map_size(state.breaker_states)
    }

    {:reply, stats, state}
  end

  def handle_call({:check_breakers, names}, _from, state) do
    result =
      Enum.reduce_while(names, :closed, fn name, min_allow_rate ->
        case Map.get(state.breaker_states, name) do
          nil ->
            {:cont, min_allow_rate}

          %{state: "open"} ->
            {:halt, :open}

          %{state: "half_open", allow_rate: rate} ->
            {:cont, merge_allow_rate(min_allow_rate, rate)}

          %{state: "closed"} ->
            {:cont, min_allow_rate}
        end
      end)

    {:reply, result, state}
  end

  defp merge_allow_rate(:closed, rate), do: {:half_open, rate}
  defp merge_allow_rate({:half_open, current}, rate), do: {:half_open, min(current, rate)}
end
