defmodule Tripswitch.Admin.IntegrationTest do
  use ExUnit.Case, async: false

  alias Tripswitch.Admin.Error

  @moduletag :integration

  setup_all do
    opts = [api_key: System.fetch_env!("TRIPSWITCH_ADMIN_KEY")]

    opts =
      case System.get_env("TRIPSWITCH_BASE_URL") do
        nil -> opts
        url -> [{:base_url, url} | opts]
      end

    client = Tripswitch.Admin.new(opts)

    {:ok,
     client: client,
     project_id: System.fetch_env!("TRIPSWITCH_PROJECT_ID"),
     workspace_id: System.fetch_env!("TRIPSWITCH_WORKSPACE_ID")}
  end

  test "get_project returns project data", %{client: client, project_id: project_id} do
    assert {:ok, project} = Tripswitch.Admin.get_project(client, project_id)
    assert is_binary(project["name"])
  end

  test "list_projects returns a list", %{client: client} do
    assert {:ok, projects} = Tripswitch.Admin.list_projects(client)
    assert is_list(projects)
  end

  test "list_projects filters by workspace_id", %{client: client, workspace_id: workspace_id} do
    assert {:ok, projects} = Tripswitch.Admin.list_projects(client, workspace_id: workspace_id)
    assert is_list(projects)
  end

  test "list_breakers returns a list", %{client: client, project_id: project_id} do
    assert {:ok, breakers} = Tripswitch.Admin.list_breakers(client, project_id)
    assert is_list(breakers)
  end

  test "list_routers returns a list", %{client: client, project_id: project_id} do
    assert {:ok, routers} = Tripswitch.Admin.list_routers(client, project_id)
    assert is_list(routers)
  end

  test "get_workspace returns workspace data", %{client: client, workspace_id: workspace_id} do
    assert {:ok, workspace} = Tripswitch.Admin.get_workspace(client, workspace_id)
    assert is_binary(workspace["id"])
  end

  test "list_project_keys returns a list", %{client: client, project_id: project_id} do
    assert {:ok, keys} = Tripswitch.Admin.list_project_keys(client, project_id)
    assert is_list(keys)
  end

  test "list_events returns events and cursor", %{client: client, project_id: project_id} do
    assert {:ok, result} = Tripswitch.Admin.list_events(client, project_id)
    assert is_list(result.events)
    assert Map.has_key?(result, :next_cursor)
  end

  test "unknown project returns not_found error", %{client: client} do
    assert {:error, error} =
             Tripswitch.Admin.get_project(client, "00000000-0000-0000-0000-000000000000")

    assert Error.not_found?(error)
  end

  test "invalid admin key returns unauthorized or forbidden error" do
    opts = [api_key: "eb_admin_invalid"]

    opts =
      case System.get_env("TRIPSWITCH_BASE_URL") do
        nil -> opts
        url -> [{:base_url, url} | opts]
      end

    bad_client = Tripswitch.Admin.new(opts)

    assert {:error, error} = Tripswitch.Admin.get_project(bad_client, "proj_any")
    assert Error.unauthorized?(error) or Error.forbidden?(error)
  end

  test "create and delete project lifecycle", %{client: client, workspace_id: workspace_id} do
    project_name = "ex-integration-test-project-#{System.os_time(:millisecond)}"

    # Create
    assert {:ok, project} =
             Tripswitch.Admin.create_project(client, %{
               name: project_name,
               workspace_id: workspace_id
             })

    assert project["name"] == project_name
    project_id = project["project_id"]

    try do
      # List — should appear
      assert {:ok, projects} = Tripswitch.Admin.list_projects(client)
      assert Enum.any?(projects, &(&1["project_id"] == project_id))

      # Delete
      assert :ok =
               Tripswitch.Admin.delete_project(client, project_id,
                 confirm_name: project_name
               )

      # Verify deletion
      assert {:error, error} = Tripswitch.Admin.get_project(client, project_id)
      assert Error.not_found?(error)
    rescue
      e ->
        # Best-effort cleanup
        Tripswitch.Admin.delete_project(client, project_id, confirm_name: project_name)
        reraise e, __STACKTRACE__
    end
  end

  test "breaker CRUD lifecycle", %{client: client, project_id: project_id} do
    breaker_name = "ex-integration-test-breaker-#{System.os_time(:millisecond)}"

    # Create
    assert {:ok, breaker} =
             Tripswitch.Admin.create_breaker(client, project_id, %{
               name: breaker_name,
               metric: "test_metric",
               kind: "error_rate",
               op: "gt",
               threshold: 0.5,
               window_ms: 60_000,
               min_count: 10
             })

    assert breaker["name"] == breaker_name
    breaker_id = breaker["id"]

    try do
      # Read
      assert {:ok, fetched} = Tripswitch.Admin.get_breaker(client, project_id, breaker_id)
      assert fetched["name"] == breaker_name

      # Update
      assert {:ok, updated} =
               Tripswitch.Admin.update_breaker(client, project_id, breaker_id, %{
                 threshold: 0.75
               })

      assert_in_delta updated["threshold"], 0.75, 0.001

      # Delete
      assert :ok = Tripswitch.Admin.delete_breaker(client, project_id, breaker_id)

      # Verify deletion
      assert {:error, error} = Tripswitch.Admin.get_breaker(client, project_id, breaker_id)
      assert Error.not_found?(error)
    rescue
      e ->
        Tripswitch.Admin.delete_breaker(client, project_id, breaker_id)
        reraise e, __STACKTRACE__
    end
  end

  test "list_notification_channels returns a list", %{client: client, project_id: project_id} do
    assert {:ok, result} = Tripswitch.Admin.list_notification_channels(client, project_id)
    assert is_list(result.channels)
  end
end
