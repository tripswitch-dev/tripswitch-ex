defmodule Tripswitch.MetadataCache do
  @moduledoc false

  # Periodically fetches breaker and router metadata from the API and updates
  # StateServer. Uses ETags for conditional GET requests to avoid redundant work.
  # Stops silently on authentication failure (401/403).

  use GenServer
  require Logger

  alias Tripswitch.{Config, Naming, StateServer}

  defstruct [:config, :timer]

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: Naming.metadata_cache(config.name))
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(%Config{meta_sync_ms: interval} = config) when interval > 0 do
    send(self(), :sync)
    {:ok, %__MODULE__{config: config}}
  end

  def init(config) do
    Logger.debug("[Tripswitch] Metadata sync disabled")
    {:ok, %__MODULE__{config: config}}
  end

  @impl true
  def handle_info(:sync, state) do
    case do_sync(state.config) do
      :ok ->
        timer = Process.send_after(self(), :sync, state.config.meta_sync_ms)
        {:noreply, %{state | timer: timer}}

      {:error, :unauthorized} ->
        Logger.warning("[Tripswitch] Metadata sync stopped: unauthorized (check api_key)")
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("[Tripswitch] Metadata sync failed: #{inspect(reason)}, will retry")
        timer = Process.send_after(self(), :sync, state.config.meta_sync_ms)
        {:noreply, %{state | timer: timer}}
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp do_sync(config) do
    with :ok <- fetch_and_update(config, "breakers", :breakers) do
      fetch_and_update(config, "routers", :routers)
    end
  end

  defp fetch_and_update(config, resource, type) do
    url = Config.metadata_url(config, resource)
    etag = StateServer.get_etag(config.name, type)

    headers =
      [{"authorization", "Bearer #{config.api_key}"}] ++
        if(etag, do: [{"if-none-match", etag}], else: [])

    case Req.get(url, headers: headers, retry: false) do
      {:ok, %{status: 304}} ->
        :ok

      {:ok, %{status: 200, body: body, headers: resp_headers}} ->
        new_etag = get_header(resp_headers, "etag")
        items = parse_items(type, body)
        StateServer.update_metadata(config.name, type, items, new_etag)
        :ok

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, :unauthorized}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_items(:breakers, body) do
    breakers = Map.get(body, "breakers", [])

    Enum.map(breakers, fn b ->
      %{
        id: b["id"],
        name: b["name"],
        metadata: b["metadata"] || %{}
      }
    end)
  end

  defp parse_items(:routers, body) do
    routers = Map.get(body, "routers", [])

    Enum.map(routers, fn r ->
      %{
        id: r["id"],
        name: r["name"],
        metadata: r["metadata"] || %{}
      }
    end)
  end

  defp get_header(headers, name) when is_list(headers) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp get_header(headers, name) when is_map(headers) do
    Map.get(headers, name)
  end
end
