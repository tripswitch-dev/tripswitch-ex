defmodule Tripswitch.Integration.RuntimeTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  setup_all do
    opts = [
      project_id: System.fetch_env!("TRIPSWITCH_PROJECT_ID"),
      api_key: System.fetch_env!("TRIPSWITCH_API_KEY"),
      ingest_secret: System.fetch_env!("TRIPSWITCH_INGEST_SECRET"),
      name: __MODULE__.Client
    ]

    opts =
      case System.get_env("TRIPSWITCH_BASE_URL") do
        nil -> opts
        url -> [{:base_url, url} | opts]
      end

    {:ok, _} = start_supervised({Tripswitch.Client, opts})

    # Allow SSE connection to establish
    Process.sleep(2_000)

    {:ok,
     breaker_name: System.fetch_env!("TRIPSWITCH_BREAKER_NAME"),
     router_id: System.fetch_env!("TRIPSWITCH_BREAKER_ROUTER_ID"),
     metric: System.fetch_env!("TRIPSWITCH_BREAKER_METRIC")}
  end

  test "get_state returns breaker state or nil", %{breaker_name: breaker_name} do
    state = Tripswitch.get_state(__MODULE__.Client, breaker_name)

    if state do
      assert state.name == breaker_name
      assert state.state in ["open", "closed", "half_open"]
    end
  end

  test "get_all_states returns a map" do
    all = Tripswitch.get_all_states(__MODULE__.Client)
    assert is_map(all)
  end

  test "stats includes expected keys" do
    stats = Tripswitch.stats(__MODULE__.Client)

    assert Map.has_key?(stats, :sse_connected)
    assert Map.has_key?(stats, :sse_reconnects)
    assert Map.has_key?(stats, :buffer_size)
  end

  test "execute runs and reports a sample", %{
    breaker_name: breaker_name,
    router_id: router_id,
    metric: metric
  } do
    result =
      Tripswitch.execute(
        __MODULE__.Client,
        fn -> {:ok, "hello"} end,
        breakers: [breaker_name],
        router: router_id,
        metrics: %{metric => :latency},
        tags: %{"test" => "integration"}
      )

    assert result == {:ok, "hello"}
  end

  test "report/2 enqueues a sample without error", %{router_id: router_id, metric: metric} do
    :ok =
      Tripswitch.report(__MODULE__.Client, %{
        router_id: router_id,
        metric: metric,
        value: 1.0,
        ok: true,
        tags: %{"test" => "integration"}
      })
  end
end
