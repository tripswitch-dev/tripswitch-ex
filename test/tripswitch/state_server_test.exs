defmodule Tripswitch.StateServerTest do
  use ExUnit.Case, async: true

  alias Tripswitch.{Config, StateServer}

  # Each test gets a unique client name to avoid cross-test registry collisions.
  setup do
    name = :"test_state_server_#{System.unique_integer([:positive])}"
    config = Config.new(project_id: "proj_test", name: name)
    start_supervised!({StateServer, config}, id: name)
    %{name: name}
  end

  test "get_state returns nil for unknown breaker", %{name: name} do
    assert StateServer.get_state(name, "unknown") == nil
  end

  test "update_breaker and get_state", %{name: name} do
    StateServer.update_breaker(name, "my-breaker", "open", nil)
    # cast is async — give it a tick
    :sys.get_state(Tripswitch.Naming.state_server(name))

    state = StateServer.get_state(name, "my-breaker")
    assert state.name == "my-breaker"
    assert state.state == "open"
  end

  test "get_all_states returns all breakers", %{name: name} do
    StateServer.update_breaker(name, "breaker-a", "closed", nil)
    StateServer.update_breaker(name, "breaker-b", "open", nil)
    :sys.get_state(Tripswitch.Naming.state_server(name))

    all = StateServer.get_all_states(name)
    assert map_size(all) == 2
    assert all["breaker-a"].state == "closed"
    assert all["breaker-b"].state == "open"
  end

  test "check_breakers returns :closed for unknown breakers", %{name: name} do
    assert StateServer.check_breakers(name, ["no-such-breaker"]) == :closed
  end

  test "check_breakers returns :open when any breaker is open", %{name: name} do
    StateServer.update_breaker(name, "a", "closed", nil)
    StateServer.update_breaker(name, "b", "open", nil)
    :sys.get_state(Tripswitch.Naming.state_server(name))

    assert StateServer.check_breakers(name, ["a", "b"]) == :open
  end

  test "check_breakers returns {:half_open, rate} when half_open", %{name: name} do
    StateServer.update_breaker(name, "a", "half_open", 0.3)
    :sys.get_state(Tripswitch.Naming.state_server(name))

    assert StateServer.check_breakers(name, ["a"]) == {:half_open, 0.3}
  end

  test "check_breakers uses min allow_rate across multiple half_open breakers", %{name: name} do
    StateServer.update_breaker(name, "a", "half_open", 0.8)
    StateServer.update_breaker(name, "b", "half_open", 0.2)
    :sys.get_state(Tripswitch.Naming.state_server(name))

    assert StateServer.check_breakers(name, ["a", "b"]) == {:half_open, 0.2}
  end

  test "on_state_change callback fires on transition", %{name: _name} do
    parent = self()

    name = :"test_cb_#{System.unique_integer([:positive])}"

    config =
      Config.new(
        project_id: "proj_test",
        name: name,
        on_state_change: fn n, from, to -> send(parent, {:transition, n, from, to}) end
      )

    start_supervised!({StateServer, config}, id: name)

    StateServer.update_breaker(name, "cb-breaker", "closed", nil)
    StateServer.update_breaker(name, "cb-breaker", "open", nil)
    :sys.get_state(Tripswitch.Naming.state_server(name))

    assert_receive {:transition, "cb-breaker", "closed", "open"}
  end
end
