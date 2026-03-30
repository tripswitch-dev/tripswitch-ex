defmodule Tripswitch.Flusher do
  @moduledoc false

  # Collects samples in a buffer and sends them to the Tripswitch ingest
  # endpoint in gzip-compressed, HMAC-signed batches.
  #
  # Flushes when: buffer reaches 500 samples OR 15 seconds elapse.
  # On shutdown (terminate/2), performs a final synchronous flush.

  use GenServer
  require Logger

  alias Tripswitch.{Config, Naming}

  @batch_size 500
  @flush_interval_ms 15_000
  @retry_delays_ms [100, 400, 1_000]

  defstruct [
    :config,
    batch: [],
    dropped_samples: 0,
    flush_failures: 0,
    last_successful_flush: nil
  ]

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: Naming.flusher(config.name))
  end

  def enqueue(client_name, sample) do
    GenServer.cast(Naming.flusher(client_name), {:enqueue, sample})
  end

  def stats(client_name) do
    GenServer.call(Naming.flusher(client_name), :stats)
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(config) do
    schedule_flush()
    {:ok, %__MODULE__{config: config}}
  end

  @impl true
  def handle_cast({:enqueue, sample}, state) do
    batch = [sample | state.batch]

    if length(batch) >= @batch_size do
      send_batch(batch, state.config)
      {:noreply, %{state | batch: []}}
    else
      {:noreply, %{state | batch: batch}}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      dropped_samples: state.dropped_samples,
      buffer_size: length(state.batch),
      flush_failures: state.flush_failures,
      last_successful_flush: state.last_successful_flush
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:flush, state) do
    state =
      if state.batch != [] do
        case send_batch(state.batch, state.config) do
          :ok ->
            %{state | batch: [], last_successful_flush: DateTime.utc_now()}

          {:error, :dropped, count} ->
            %{
              state
              | batch: [],
                dropped_samples: state.dropped_samples + count,
                flush_failures: state.flush_failures + 1
            }
        end
      else
        state
      end

    schedule_flush()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.batch != [] do
      Logger.debug("[Tripswitch] Flushing #{length(state.batch)} samples on shutdown")
      send_batch(state.batch, state.config)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  defp send_batch(batch, config) do
    payload = %{samples: Enum.reverse(batch)}

    with {:ok, json} <- Jason.encode(payload),
         {:ok, compressed} <- gzip(json),
         {:ok, ts_ms, signature} <- sign(compressed, config) do
      do_send(compressed, ts_ms, signature, config)
    else
      {:error, reason} ->
        Logger.error("[Tripswitch] Failed to prepare batch: #{inspect(reason)}")
        {:error, :dropped, length(batch)}
    end
  end

  defp gzip(data) do
    {:ok, :zlib.gzip(data)}
  rescue
    e -> {:error, e}
  end

  defp sign(_compressed, %Config{ingest_secret: nil}) do
    ts_ms = System.os_time(:millisecond)
    {:ok, ts_ms, nil}
  end

  defp sign(compressed, %Config{ingest_secret: secret}) do
    ts_ms = System.os_time(:millisecond)

    case Base.decode16(secret, case: :lower) do
      {:ok, secret_bytes} ->
        message = "#{ts_ms}.#{compressed}"
        mac = :crypto.mac(:hmac, :sha256, secret_bytes, message)
        signature = "v1=" <> Base.encode16(mac, case: :lower)
        {:ok, ts_ms, signature}

      :error ->
        {:error, :invalid_ingest_secret}
    end
  end

  defp do_send(compressed, ts_ms, signature, config) do
    url = Config.ingest_url(config)

    headers =
      [
        {"content-type", "application/json"},
        {"content-encoding", "gzip"},
        {"x-eb-timestamp", Integer.to_string(ts_ms)}
      ] ++ if(signature, do: [{"x-eb-signature", signature}], else: [])

    Enum.reduce_while([nil | @retry_delays_ms], {:error, :retries_exhausted}, fn delay, _acc ->
      if delay, do: Process.sleep(delay)

      case Req.post(url, body: compressed, headers: headers, retry: false) do
        {:ok, %{status: status}} when status in 200..299 ->
          {:halt, :ok}

        {:ok, %{status: status}} when status in 400..499 ->
          Logger.error("[Tripswitch] Ingest rejected (#{status}), dropping batch")
          {:halt, {:error, :dropped, 0}}

        {:ok, %{status: status}} ->
          Logger.warning("[Tripswitch] Ingest failed (#{status}), retrying")
          {:cont, {:error, :server_error}}

        {:error, reason} ->
          Logger.warning("[Tripswitch] Ingest request error: #{inspect(reason)}, retrying")
          {:cont, {:error, reason}}
      end
    end)
    |> case do
      :ok -> :ok
      _ -> {:error, :dropped, 0}
    end
  end
end
