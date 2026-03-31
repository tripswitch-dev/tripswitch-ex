defmodule Tripswitch.Admin.Error do
  @moduledoc """
  Represents an error returned by the Tripswitch management API.

  ## Fields

  - `:status` — HTTP status code
  - `:code` — machine-readable error code string from the API (may be `nil`)
  - `:message` — human-readable description
  - `:request_id` — `X-Request-Id` header value (useful for support requests)
  - `:retry_after` — seconds to wait before retrying (populated on 429 responses)
  """

  @enforce_keys [:status, :message]
  defstruct [:status, :code, :message, :request_id, :retry_after]

  @type t :: %__MODULE__{
          status: pos_integer(),
          code: String.t() | nil,
          message: String.t(),
          request_id: String.t() | nil,
          retry_after: non_neg_integer() | nil
        }

  @doc "Returns `true` for 404 responses."
  @spec not_found?(t() | term()) :: boolean()
  def not_found?(%__MODULE__{status: 404}), do: true
  def not_found?(_), do: false

  @doc "Returns `true` for 401 responses."
  @spec unauthorized?(t() | term()) :: boolean()
  def unauthorized?(%__MODULE__{status: 401}), do: true
  def unauthorized?(_), do: false

  @doc "Returns `true` for 403 responses."
  @spec forbidden?(t() | term()) :: boolean()
  def forbidden?(%__MODULE__{status: 403}), do: true
  def forbidden?(_), do: false

  @doc "Returns `true` for 422 responses."
  @spec unprocessable?(t() | term()) :: boolean()
  def unprocessable?(%__MODULE__{status: 422}), do: true
  def unprocessable?(_), do: false

  @doc "Returns `true` for 429 responses."
  @spec rate_limited?(t() | term()) :: boolean()
  def rate_limited?(%__MODULE__{status: 429}), do: true
  def rate_limited?(_), do: false

  @doc "Returns `true` for 5xx responses."
  @spec server_error?(t() | term()) :: boolean()
  def server_error?(%__MODULE__{status: s}) when s in 500..599, do: true
  def server_error?(_), do: false
end
