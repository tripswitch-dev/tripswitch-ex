defmodule Tripswitch.Admin.ErrorTest do
  use ExUnit.Case, async: true

  alias Tripswitch.Admin.Error

  defp error(status), do: %Error{status: status, message: "test"}

  test "not_found? is true for 404" do
    assert Error.not_found?(error(404)) == true
    assert Error.not_found?(error(400)) == false
  end

  test "unauthorized? is true for 401" do
    assert Error.unauthorized?(error(401)) == true
    assert Error.unauthorized?(error(403)) == false
  end

  test "forbidden? is true for 403" do
    assert Error.forbidden?(error(403)) == true
    assert Error.forbidden?(error(401)) == false
  end

  test "unprocessable? is true for 422" do
    assert Error.unprocessable?(error(422)) == true
    assert Error.unprocessable?(error(400)) == false
  end

  test "rate_limited? is true for 429" do
    assert Error.rate_limited?(error(429)) == true
    assert Error.rate_limited?(error(422)) == false
  end

  test "server_error? is true for 5xx" do
    assert Error.server_error?(error(500)) == true
    assert Error.server_error?(error(503)) == true
    assert Error.server_error?(error(404)) == false
    assert Error.server_error?(error(429)) == false
  end
end
