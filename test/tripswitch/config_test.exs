defmodule Tripswitch.ConfigTest do
  use ExUnit.Case, async: true

  alias Tripswitch.Config

  test "new/1 requires project_id" do
    assert_raise KeyError, fn -> Config.new([]) end
  end

  test "new/1 defaults" do
    config = Config.new(project_id: "proj_abc", name: :test)

    assert config.project_id == "proj_abc"
    assert config.fail_open == true
    assert config.base_url == "https://api.tripswitch.dev"
    assert config.meta_sync_ms == 30_000
    assert config.global_tags == %{}
    assert is_nil(config.api_key)
    assert is_nil(config.ingest_secret)
  end

  test "new/1 accepts all options" do
    config =
      Config.new(
        project_id: "proj_123",
        name: :my_client,
        api_key: "eb_pk_test",
        ingest_secret: "deadbeef",
        fail_open: false,
        base_url: "http://localhost:4009",
        meta_sync_ms: 5_000,
        global_tags: %{"env" => "test"}
      )

    assert config.api_key == "eb_pk_test"
    assert config.ingest_secret == "deadbeef"
    assert config.fail_open == false
    assert config.base_url == "http://localhost:4009"
    assert config.meta_sync_ms == 5_000
    assert config.global_tags == %{"env" => "test"}
  end

  test "sse_url/1 builds correct URL" do
    config = Config.new(project_id: "proj_abc", name: :test)

    assert Config.sse_url(config) ==
             "https://api.tripswitch.dev/v1/projects/proj_abc/breakers/state:stream"
  end

  test "ingest_url/1 builds correct URL" do
    config = Config.new(project_id: "proj_abc", name: :test)
    assert Config.ingest_url(config) == "https://api.tripswitch.dev/v1/projects/proj_abc/ingest"
  end
end
