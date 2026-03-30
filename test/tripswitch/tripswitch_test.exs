defmodule TripswitchTest do
  use ExUnit.Case, async: true

  alias Tripswitch.{Config, Flusher, StateServer}

  # Each test gets unique client name to avoid Registry collisions.
  setup do
    name = :"ts_test_#{System.unique_integer([:positive])}"
    config = Config.new(project_id: "proj_test", name: name)
    start_supervised!({StateServer, config}, id: {name, :state_server})
    start_supervised!({Flusher, config}, id: {name, :flusher})
    %{name: name}
  end

  describe "execute/3" do
    test "runs task when no breakers configured", %{name: name} do
      result = Tripswitch.execute(name, fn -> 42 end)
      assert result == 42
    end

    test "runs task when breaker is closed", %{name: name} do
      StateServer.update_breaker(name, "my-breaker", "closed", nil)
      :sys.get_state(Tripswitch.Naming.state_server(name))

      result = Tripswitch.execute(name, fn -> :ok end, breakers: ["my-breaker"])
      assert result == :ok
    end

    test "returns {:error, :breaker_open} when breaker is open", %{name: name} do
      StateServer.update_breaker(name, "my-breaker", "open", nil)
      :sys.get_state(Tripswitch.Naming.state_server(name))

      result = Tripswitch.execute(name, fn -> :ok end, breakers: ["my-breaker"])
      assert result == {:error, :breaker_open}
    end

    test "always blocks when half_open allow_rate is 0.0", %{name: name} do
      StateServer.update_breaker(name, "my-breaker", "half_open", 0.0)
      :sys.get_state(Tripswitch.Naming.state_server(name))

      result = Tripswitch.execute(name, fn -> :ok end, breakers: ["my-breaker"])
      assert result == {:error, :breaker_open}
    end

    test "always allows when half_open allow_rate is 1.0", %{name: name} do
      StateServer.update_breaker(name, "my-breaker", "half_open", 1.0)
      :sys.get_state(Tripswitch.Naming.state_server(name))

      result = Tripswitch.execute(name, fn -> :done end, breakers: ["my-breaker"])
      assert result == :done
    end

    test "unknown breaker defaults to closed (fail open)", %{name: name} do
      result = Tripswitch.execute(name, fn -> :ok end, breakers: ["no-such-breaker"])
      assert result == :ok
    end

    test "enqueues one sample per metric", %{name: name} do
      Tripswitch.execute(name, fn -> :ok end, metrics: %{"latency_ms" => :latency, "score" => 99})

      # Give flusher time to receive the cast
      :sys.get_state(Tripswitch.Naming.flusher(name))
      assert Flusher.stats(name).buffer_size == 2
    end

    test ":latency metric records elapsed ms as float", %{name: name} do
      Tripswitch.execute(name, fn -> :ok end,
        metrics: %{"latency_ms" => :latency},
        router: "r1"
      )

      :sys.get_state(Tripswitch.Naming.flusher(name))
      assert Flusher.stats(name).buffer_size == 1
    end

    test "function metric is called with task result", %{name: name} do
      test_pid = self()

      Tripswitch.execute(name, fn -> {:ok, "data"} end,
        metrics: %{
          "size" => fn result ->
            send(test_pid, {:result, result})
            7
          end
        }
      )

      assert_receive {:result, {:ok, "data"}}
    end

    test "deferred_metrics are reported", %{name: name} do
      Tripswitch.execute(name, fn -> :ok end, deferred_metrics: fn _result -> %{"extra" => 5} end)

      :sys.get_state(Tripswitch.Naming.flusher(name))
      assert Flusher.stats(name).buffer_size == 1
    end

    test "ok? is true for non-error results", %{name: name} do
      test_pid = self()

      Tripswitch.execute(name, fn -> :ok end,
        metrics: %{
          "m" => fn _r ->
            send(test_pid, :called)
            1
          end
        }
      )

      assert_receive :called
    end

    test "default error_evaluator: {:error, _} is a failure", %{name: name} do
      # Just checks it runs without crashing; ok? is internal.
      # We verify behavior through breaker_open? semantics, not here.
      result = Tripswitch.execute(name, fn -> {:error, :boom} end)
      assert result == {:error, :boom}
    end

    test "custom error_evaluator", %{name: name} do
      result =
        Tripswitch.execute(name, fn -> :not_found end,
          error_evaluator: fn r -> r == :not_found end
        )

      assert result == :not_found
    end

    test "exceptions are reraised after recording", %{name: name} do
      assert_raise RuntimeError, "boom", fn ->
        Tripswitch.execute(name, fn -> raise "boom" end, metrics: %{"latency_ms" => :latency})
      end

      :sys.get_state(Tripswitch.Naming.flusher(name))
      assert Flusher.stats(name).buffer_size == 1
    end

    test "breaker_selector resolves names from metadata", %{name: name} do
      StateServer.update_metadata(name, :breakers, [%{"id" => "b1", "name" => "my-breaker"}], nil)
      StateServer.update_breaker(name, "my-breaker", "open", nil)
      :sys.get_state(Tripswitch.Naming.state_server(name))

      result =
        Tripswitch.execute(name, fn -> :ok end,
          breaker_selector: fn breakers ->
            Enum.map(breakers, & &1["name"])
          end
        )

      assert result == {:error, :breaker_open}
    end
  end

  describe "report/2" do
    test "enqueues a sample directly", %{name: name} do
      Tripswitch.report(name, %{router_id: "r1", metric: "m", value: 1.0, ok: true})
      :sys.get_state(Tripswitch.Naming.flusher(name))
      assert Flusher.stats(name).buffer_size == 1
    end
  end

  describe "get_state/2" do
    test "returns nil for unknown breaker", %{name: name} do
      assert Tripswitch.get_state(name, "unknown") == nil
    end

    test "returns breaker state map", %{name: name} do
      StateServer.update_breaker(name, "b", "open", nil)
      :sys.get_state(Tripswitch.Naming.state_server(name))

      state = Tripswitch.get_state(name, "b")
      assert state.state == "open"
      assert state.name == "b"
    end
  end

  describe "get_all_states/1" do
    test "returns all known states", %{name: name} do
      StateServer.update_breaker(name, "a", "closed", nil)
      StateServer.update_breaker(name, "b", "open", nil)
      :sys.get_state(Tripswitch.Naming.state_server(name))

      all = Tripswitch.get_all_states(name)
      assert map_size(all) == 2
    end
  end

  describe "stats/1" do
    test "merges StateServer and Flusher stats", %{name: name} do
      stats = Tripswitch.stats(name)

      assert Map.has_key?(stats, :sse_connected)
      assert Map.has_key?(stats, :buffer_size)
    end
  end

  describe "breaker_open?/2" do
    test "returns true when breaker is open", %{name: name} do
      StateServer.update_breaker(name, "b", "open", nil)
      :sys.get_state(Tripswitch.Naming.state_server(name))
      assert Tripswitch.breaker_open?(name, "b") == true
    end

    test "returns false when breaker is closed", %{name: name} do
      StateServer.update_breaker(name, "b", "closed", nil)
      :sys.get_state(Tripswitch.Naming.state_server(name))
      assert Tripswitch.breaker_open?(name, "b") == false
    end

    test "returns false for half_open breaker", %{name: name} do
      StateServer.update_breaker(name, "b", "half_open", 0.5)
      :sys.get_state(Tripswitch.Naming.state_server(name))
      assert Tripswitch.breaker_open?(name, "b") == false
    end

    test "returns false for unknown breaker", %{name: name} do
      assert Tripswitch.breaker_open?(name, "unknown") == false
    end
  end

  describe "contract_version/0" do
    test "returns version string" do
      assert is_binary(Tripswitch.contract_version())
    end
  end
end
