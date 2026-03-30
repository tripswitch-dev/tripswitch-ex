defmodule Tripswitch.Client do
  @moduledoc """
  Supervisor for a Tripswitch runtime client instance.

  Start it under your application's supervision tree:

      children = [
        {Tripswitch.Client,
          project_id: "proj_abc123",
          api_key: "eb_pk_...",
          ingest_secret: "...",
          name: MyApp.Tripswitch}
      ]

  Then use the `Tripswitch` module to wrap calls and report metrics.
  See `Tripswitch` for the full public API.
  """

  use Supervisor

  alias Tripswitch.Config

  @doc """
  Starts a Tripswitch client supervisor.

  ## Options

    * `:project_id` — **(required)** your Tripswitch project ID
    * `:api_key` — project key (`eb_pk_...`) for SSE state sync
    * `:ingest_secret` — 64-char hex string for HMAC-signed sample ingestion
    * `:name` — registered name for the client (default: `Tripswitch.Client`)
    * `:fail_open` — allow traffic when Tripswitch is unreachable (default: `true`)
    * `:base_url` — override the API base URL (default: `"https://api.tripswitch.dev"`)
    * `:meta_sync_ms` — metadata refresh interval in ms (default: `30_000`; `0` to disable)
    * `:on_state_change` — `fn name, from_state, to_state -> :ok end` callback
    * `:global_tags` — tags applied to all samples, e.g. `%{"env" => "production"}`
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    config = Config.new(opts)

    children = [
      {Tripswitch.StateServer, config},
      {Tripswitch.SSEListener, config},
      {Tripswitch.Flusher, config},
      {Tripswitch.MetadataCache, config}
    ]

    # rest_for_one: if StateServer crashes, restart SSEListener and friends too
    # since they depend on it being alive.
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
