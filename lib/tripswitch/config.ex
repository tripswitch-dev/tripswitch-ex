defmodule Tripswitch.Config do
  @moduledoc false

  @default_base_url "https://api.tripswitch.dev"
  @default_meta_sync_ms 30_000

  @enforce_keys [:project_id, :name]
  defstruct [
    :project_id,
    :api_key,
    :ingest_secret,
    :name,
    :on_state_change,
    fail_open: true,
    base_url: @default_base_url,
    meta_sync_ms: @default_meta_sync_ms,
    global_tags: %{}
  ]

  def new(opts) do
    %__MODULE__{
      project_id: Keyword.fetch!(opts, :project_id),
      api_key: Keyword.get(opts, :api_key),
      ingest_secret: Keyword.get(opts, :ingest_secret),
      name: Keyword.get(opts, :name, Tripswitch.Client),
      fail_open: Keyword.get(opts, :fail_open, true),
      base_url: Keyword.get(opts, :base_url, @default_base_url),
      meta_sync_ms: Keyword.get(opts, :meta_sync_ms, @default_meta_sync_ms),
      on_state_change: Keyword.get(opts, :on_state_change),
      global_tags: opts |> Keyword.get(:global_tags, %{}) |> Map.new()
    }
  end

  def sse_url(%__MODULE__{base_url: base, project_id: pid}),
    do: "#{base}/v1/projects/#{pid}/breakers/state:stream"

  def ingest_url(%__MODULE__{base_url: base, project_id: pid}),
    do: "#{base}/v1/projects/#{pid}/ingest"

  def metadata_url(%__MODULE__{base_url: base, project_id: pid}, resource),
    do: "#{base}/v1/projects/#{pid}/#{resource}/metadata"
end
