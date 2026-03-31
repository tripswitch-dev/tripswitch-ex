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
end
