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

    # Wait until the initial SSE state snapshot has been fully processed
    wait_until!(fn -> Tripswitch.stats(__MODULE__.Client).cached_breakers > 0 end,
      timeout: 5_000,
      interval: 50
    )

    {:ok,
     breaker_name: System.fetch_env!("TRIPSWITCH_BREAKER_NAME"),
     router_id: System.fetch_env!("TRIPSWITCH_BREAKER_ROUTER_ID"),
     metric: System.fetch_env!("TRIPSWITCH_BREAKER_METRIC")}
  end

  test "SSE is connected and delivered initial state snapshot" do
    stats = Tripswitch.stats(__MODULE__.Client)
    assert stats.sse_connected == true
    assert stats.sse_reconnects == 0
    assert stats.cached_breakers > 0, "expected SSE initial snapshot to populate breaker states"
  end

  test "get_state returns known breaker state", %{breaker_name: breaker_name} do
    state = Tripswitch.get_state(__MODULE__.Client, breaker_name)
    assert state != nil, "expected SSE to have delivered state for #{breaker_name}"
    assert state.name == breaker_name
    assert state.state in ["open", "closed", "half_open"]
  end

  test "get_all_states returns non-empty map" do
    all = Tripswitch.get_all_states(__MODULE__.Client)
    assert map_size(all) > 0, "expected SSE snapshot to have populated at least one breaker"
  end

  test "stats reports sse_connected true" do
    stats = Tripswitch.stats(__MODULE__.Client)
    assert stats.sse_connected == true
    assert Map.has_key?(stats, :sse_reconnects)
    assert Map.has_key?(stats, :buffer_size)
  end

  test "metadata sync populates breakers and routers" do
    breakers = Tripswitch.get_breakers_metadata(__MODULE__.Client)
    routers = Tripswitch.get_routers_metadata(__MODULE__.Client)

    assert is_list(breakers)
    assert is_list(routers)

    assert breakers != [] or routers != [],
           "expected metadata sync to have fetched at least one breaker or router"

    if breakers != [] do
      [b | _] = breakers
      assert is_binary(b.id)
      assert is_binary(b.name)
      assert is_map(b.metadata)
    end
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

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp wait_until!(fun, opts) do
    interval = Keyword.get(opts, :interval, 50)
    timeout = Keyword.get(opts, :timeout, 5_000)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until!(fun, deadline, interval, timeout)
  end

  defp do_wait_until!(fun, deadline, interval, original_timeout) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk(
          "SSE failed to deliver initial state snapshot within #{original_timeout}ms — check api_key and base_url"
        )
      end

      Process.sleep(interval)
      do_wait_until!(fun, deadline, interval, original_timeout)
    end
  end
end
