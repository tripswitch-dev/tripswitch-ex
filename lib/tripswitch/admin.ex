defmodule Tripswitch.Admin do
  @moduledoc """
  Stateless client for the Tripswitch management API.

  Requires an admin API key (`eb_admin_...`). Admin keys are org-scoped and
  grant access to all workspaces and projects within the org.

  ## Quick start

      client = Tripswitch.Admin.new(api_key: "eb_admin_...")

      {:ok, project} = Tripswitch.Admin.get_project(client, "proj_abc123")

      {:ok, breakers} = Tripswitch.Admin.list_breakers(client, "proj_abc123")

  ## Error handling

  All functions return `{:ok, result}` or `{:error, %Tripswitch.Admin.Error{}}`.
  Transport failures return `{:error, exception}`.

      case Tripswitch.Admin.get_breaker(client, project_id, breaker_id) do
        {:ok, breaker} -> breaker
        {:error, %Tripswitch.Admin.Error{} = err} ->
          if Tripswitch.Admin.Error.not_found?(err), do: nil, else: raise "unexpected error"
        {:error, reason} -> raise "transport error: \#{inspect(reason)}"
      end
  """

  alias Tripswitch.Admin.Error

  @default_base_url "https://api.tripswitch.dev"

  @enforce_keys [:api_key]
  defstruct [:api_key, base_url: @default_base_url]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t()
        }

  @doc """
  Creates a new admin client.

  ## Options

  - `:api_key` — (required) admin API key (`eb_admin_...`)
  - `:base_url` — override the default API base URL
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      api_key: Keyword.fetch!(opts, :api_key),
      base_url: Keyword.get(opts, :base_url, @default_base_url)
    }
  end

  # ---------------------------------------------------------------------------
  # Workspaces
  # ---------------------------------------------------------------------------

  @doc "Lists all workspaces for the authenticated org."
  @spec list_workspaces(t()) :: {:ok, list(map())} | {:error, Error.t() | term()}
  def list_workspaces(client) do
    with {:ok, body} <- request(client, :get, "/v1/workspaces") do
      {:ok, Map.get(body, "workspaces", [])}
    end
  end

  @doc "Creates a new workspace."
  @spec create_workspace(t(), map()) :: {:ok, map()} | {:error, Error.t() | term()}
  def create_workspace(client, params) do
    request(client, :post, "/v1/workspaces", body: params)
  end

  @doc "Retrieves a workspace by ID."
  @spec get_workspace(t(), String.t()) :: {:ok, map()} | {:error, Error.t() | term()}
  def get_workspace(client, workspace_id) do
    request(client, :get, "/v1/workspaces/#{workspace_id}")
  end

  @doc "Updates a workspace's settings."
  @spec update_workspace(t(), String.t(), map()) :: {:ok, map()} | {:error, Error.t() | term()}
  def update_workspace(client, workspace_id, params) do
    request(client, :patch, "/v1/workspaces/#{workspace_id}", body: params)
  end

  @doc "Deletes a workspace by ID."
  @spec delete_workspace(t(), String.t()) :: :ok | {:error, Error.t() | term()}
  def delete_workspace(client, workspace_id) do
    with {:ok, _} <- request(client, :delete, "/v1/workspaces/#{workspace_id}"), do: :ok
  end

  # ---------------------------------------------------------------------------
  # Projects
  # ---------------------------------------------------------------------------

  @doc """
  Lists all projects for the authenticated org.

  ## Options

  - `:workspace_id` — filter by workspace
  """
  @spec list_projects(t(), keyword()) :: {:ok, list(map())} | {:error, Error.t() | term()}
  def list_projects(client, opts \\ []) do
    params = if id = opts[:workspace_id], do: %{workspace_id: id}, else: %{}

    with {:ok, body} <- request(client, :get, "/v1/projects", params: params) do
      {:ok, Map.get(body, "projects", [])}
    end
  end

  @doc "Creates a new project."
  @spec create_project(t(), map()) :: {:ok, map()} | {:error, Error.t() | term()}
  def create_project(client, params) do
    request(client, :post, "/v1/projects", body: params)
  end

  @doc "Retrieves a project by ID."
  @spec get_project(t(), String.t()) :: {:ok, map()} | {:error, Error.t() | term()}
  def get_project(client, project_id) do
    request(client, :get, "/v1/projects/#{project_id}")
  end

  @doc "Updates a project's settings."
  @spec update_project(t(), String.t(), map()) :: {:ok, map()} | {:error, Error.t() | term()}
  def update_project(client, project_id, params) do
    request(client, :patch, "/v1/projects/#{project_id}", body: params)
  end

  @doc """
  Deletes a project by ID.

  Requires `confirm_name:` to match the project's actual name. This safety
  guard prevents accidental deletion by verifying the name before sending
  the DELETE request.

      Tripswitch.Admin.delete_project(client, "proj_123", confirm_name: "prod-payments")
  """
  @spec delete_project(t(), String.t(), keyword()) :: :ok | {:error, Error.t() | term()}
  def delete_project(client, project_id, opts \\ []) do
    confirm =
      opts[:confirm_name] || raise ArgumentError, ":confirm_name is required for delete_project"

    with {:ok, project} <- get_project(client, project_id),
         :ok <- verify_project_name(project, confirm),
         {:ok, _} <- request(client, :delete, "/v1/projects/#{project_id}") do
      :ok
    end
  end

  @doc "Rotates the ingest secret for a project. Returns the new secret string."
  @spec rotate_ingest_secret(t(), String.t()) ::
          {:ok, String.t()} | {:error, Error.t() | term()}
  def rotate_ingest_secret(client, project_id) do
    with {:ok, body} <- request(client, :post, "/v1/projects/#{project_id}/ingest_secret/rotate") do
      {:ok, body["ingest_secret"]}
    end
  end

  # ---------------------------------------------------------------------------
  # Breakers
  # ---------------------------------------------------------------------------

  @doc """
  Lists all breakers for a project.

  ## Options

  - `:cursor` — pagination cursor
  - `:limit` — maximum number of results
  """
  @spec list_breakers(t(), String.t(), keyword()) ::
          {:ok, list(map())} | {:error, Error.t() | term()}
  def list_breakers(client, project_id, opts \\ []) do
    params = build_list_params(opts)

    with {:ok, body} <-
           request(client, :get, "/v1/projects/#{project_id}/breakers", params: params) do
      {:ok, Map.get(body, "breakers", [])}
    end
  end

  @doc "Creates a new breaker."
  @spec create_breaker(t(), String.t(), map()) :: {:ok, map()} | {:error, Error.t() | term()}
  def create_breaker(client, project_id, params) do
    with {:ok, body} <-
           request(client, :post, "/v1/projects/#{project_id}/breakers", body: params) do
      {:ok, flatten_breaker(body)}
    end
  end

  @doc "Retrieves a specific breaker."
  @spec get_breaker(t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t() | term()}
  def get_breaker(client, project_id, breaker_id) do
    with {:ok, body} <-
           request(client, :get, "/v1/projects/#{project_id}/breakers/#{breaker_id}") do
      {:ok, flatten_breaker(body)}
    end
  end

  @doc "Updates a breaker's configuration."
  @spec update_breaker(t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t() | term()}
  def update_breaker(client, project_id, breaker_id, params) do
    with {:ok, body} <-
           request(client, :patch, "/v1/projects/#{project_id}/breakers/#{breaker_id}",
             body: params
           ) do
      {:ok, flatten_breaker(body)}
    end
  end

  @doc "Deletes a breaker."
  @spec delete_breaker(t(), String.t(), String.t()) :: :ok | {:error, Error.t() | term()}
  def delete_breaker(client, project_id, breaker_id) do
    with {:ok, _} <-
           request(client, :delete, "/v1/projects/#{project_id}/breakers/#{breaker_id}"),
         do: :ok
  end

  @doc "Bulk-replaces all breakers for a project."
  @spec sync_breakers(t(), String.t(), list(map())) ::
          {:ok, list(map())} | {:error, Error.t() | term()}
  def sync_breakers(client, project_id, breakers) do
    request(client, :put, "/v1/projects/#{project_id}/breakers", body: %{breakers: breakers})
  end

  @doc "Retrieves the current state of a single breaker."
  @spec get_breaker_state(t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t() | term()}
  def get_breaker_state(client, project_id, breaker_id) do
    request(client, :get, "/v1/projects/#{project_id}/breakers/#{breaker_id}/state")
  end

  @doc """
  Retrieves states for multiple breakers in a single request.

  Pass either `breaker_ids: [...]` or `router_id: "..."` in params.
  """
  @spec batch_get_breaker_states(t(), String.t(), map()) ::
          {:ok, list(map())} | {:error, Error.t() | term()}
  def batch_get_breaker_states(client, project_id, params) do
    request(client, :post, "/v1/projects/#{project_id}/breakers/state:batch", body: params)
  end

  # ---------------------------------------------------------------------------
  # Routers
  # ---------------------------------------------------------------------------

  @doc """
  Lists all routers for a project.

  ## Options

  - `:cursor` — pagination cursor
  - `:limit` — maximum number of results
  """
  @spec list_routers(t(), String.t(), keyword()) ::
          {:ok, list(map())} | {:error, Error.t() | term()}
  def list_routers(client, project_id, opts \\ []) do
    params = build_list_params(opts)

    with {:ok, body} <-
           request(client, :get, "/v1/projects/#{project_id}/routers", params: params) do
      {:ok, Map.get(body, "routers", [])}
    end
  end

  @doc "Creates a new router."
  @spec create_router(t(), String.t(), map()) :: {:ok, map()} | {:error, Error.t() | term()}
  def create_router(client, project_id, params) do
    request(client, :post, "/v1/projects/#{project_id}/routers", body: params)
  end

  @doc "Retrieves a specific router."
  @spec get_router(t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t() | term()}
  def get_router(client, project_id, router_id) do
    request(client, :get, "/v1/projects/#{project_id}/routers/#{router_id}")
  end

  @doc "Updates a router's configuration."
  @spec update_router(t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t() | term()}
  def update_router(client, project_id, router_id, params) do
    request(client, :patch, "/v1/projects/#{project_id}/routers/#{router_id}", body: params)
  end

  @doc "Deletes a router. The router must have no linked breakers."
  @spec delete_router(t(), String.t(), String.t()) :: :ok | {:error, Error.t() | term()}
  def delete_router(client, project_id, router_id) do
    with {:ok, _} <- request(client, :delete, "/v1/projects/#{project_id}/routers/#{router_id}"),
         do: :ok
  end

  @doc "Links a breaker to a router."
  @spec link_breaker(t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, Error.t() | term()}
  def link_breaker(client, project_id, router_id, breaker_id) do
    with {:ok, _} <-
           request(client, :post, "/v1/projects/#{project_id}/routers/#{router_id}/breakers",
             body: %{breaker_id: breaker_id}
           ),
         do: :ok
  end

  @doc "Removes a breaker from a router."
  @spec unlink_breaker(t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, Error.t() | term()}
  def unlink_breaker(client, project_id, router_id, breaker_id) do
    with {:ok, _} <-
           request(
             client,
             :delete,
             "/v1/projects/#{project_id}/routers/#{router_id}/breakers/#{breaker_id}"
           ),
         do: :ok
  end

  # ---------------------------------------------------------------------------
  # Notification channels
  # ---------------------------------------------------------------------------

  @doc """
  Lists all notification channels for a project.

  ## Options

  - `:cursor` — pagination cursor
  - `:limit` — maximum number of results
  """
  @spec list_notification_channels(t(), String.t(), keyword()) ::
          {:ok, %{items: list(map()), next_cursor: String.t() | nil}}
          | {:error, Error.t() | term()}
  def list_notification_channels(client, project_id, opts \\ []) do
    params = build_list_params(opts)

    with {:ok, body} <-
           request(client, :get, "/v1/projects/#{project_id}/notification-channels",
             params: params
           ) do
      {:ok, %{items: Map.get(body, "items", []), next_cursor: body["next_cursor"]}}
    end
  end

  @doc "Creates a new notification channel."
  @spec create_notification_channel(t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t() | term()}
  def create_notification_channel(client, project_id, params) do
    request(client, :post, "/v1/projects/#{project_id}/notification-channels", body: params)
  end

  @doc "Retrieves a specific notification channel."
  @spec get_notification_channel(t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t() | term()}
  def get_notification_channel(client, project_id, channel_id) do
    request(client, :get, "/v1/projects/#{project_id}/notification-channels/#{channel_id}")
  end

  @doc "Updates a notification channel's configuration."
  @spec update_notification_channel(t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t() | term()}
  def update_notification_channel(client, project_id, channel_id, params) do
    request(client, :patch, "/v1/projects/#{project_id}/notification-channels/#{channel_id}",
      body: params
    )
  end

  @doc "Deletes a notification channel."
  @spec delete_notification_channel(t(), String.t(), String.t()) ::
          :ok | {:error, Error.t() | term()}
  def delete_notification_channel(client, project_id, channel_id) do
    with {:ok, _} <-
           request(
             client,
             :delete,
             "/v1/projects/#{project_id}/notification-channels/#{channel_id}"
           ),
         do: :ok
  end

  @doc "Sends a test notification to a channel."
  @spec test_notification_channel(t(), String.t(), String.t()) ::
          :ok | {:error, Error.t() | term()}
  def test_notification_channel(client, project_id, channel_id) do
    with {:ok, _} <-
           request(
             client,
             :post,
             "/v1/projects/#{project_id}/notification-channels/#{channel_id}/test"
           ),
         do: :ok
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @doc """
  Lists state transition events for a project.

  ## Options

  - `:breaker_id` — filter by breaker
  - `:start_time` — filter events after this `DateTime`
  - `:end_time` — filter events before this `DateTime`
  - `:cursor` — pagination cursor
  - `:limit` — maximum number of results
  """
  @spec list_events(t(), String.t(), keyword()) ::
          {:ok, %{events: list(map()), next_cursor: String.t() | nil}}
          | {:error, Error.t() | term()}
  def list_events(client, project_id, opts \\ []) do
    params =
      []
      |> maybe_put(:breaker_id, opts[:breaker_id])
      |> maybe_put(:start_time, opts[:start_time] && DateTime.to_iso8601(opts[:start_time]))
      |> maybe_put(:end_time, opts[:end_time] && DateTime.to_iso8601(opts[:end_time]))
      |> maybe_put(:cursor, opts[:cursor])
      |> maybe_put(:limit, opts[:limit])
      |> Map.new()

    with {:ok, body} <-
           request(client, :get, "/v1/projects/#{project_id}/events", params: params) do
      {:ok, %{events: Map.get(body, "events", []), next_cursor: body["next_cursor"]}}
    end
  end

  # ---------------------------------------------------------------------------
  # Project keys
  # ---------------------------------------------------------------------------

  @doc "Lists all project API keys."
  @spec list_project_keys(t(), String.t()) ::
          {:ok, list(map())} | {:error, Error.t() | term()}
  def list_project_keys(client, project_id) do
    with {:ok, body} <- request(client, :get, "/v1/projects/#{project_id}/keys") do
      {:ok, Map.get(body, "keys", [])}
    end
  end

  @doc """
  Creates a new project API key.

  The returned map includes a `"key"` field containing the full `eb_pk_...` value.
  This is the only time the key is returned — store it securely.
  """
  @spec create_project_key(t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t() | term()}
  def create_project_key(client, project_id, params \\ %{}) do
    request(client, :post, "/v1/projects/#{project_id}/keys", body: params)
  end

  @doc "Revokes a project API key. Once revoked, the key cannot be used for authentication."
  @spec delete_project_key(t(), String.t(), String.t()) :: :ok | {:error, Error.t() | term()}
  def delete_project_key(client, project_id, key_id) do
    with {:ok, _} <- request(client, :delete, "/v1/projects/#{project_id}/keys/#{key_id}"),
         do: :ok
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp request(client, method, path, opts \\ []) do
    url = client.base_url <> path

    headers = [
      {"authorization", "Bearer #{client.api_key}"},
      {"accept", "application/json"}
    ]

    req_opts =
      [headers: headers, retry: false]
      |> maybe_put_req(:params, opts[:params])
      |> maybe_put_req(:json, opts[:body])

    case dispatch(method, url, req_opts) do
      {:ok, %{status: s, body: body}} when s in 200..299 ->
        {:ok, body || %{}}

      {:ok, %{status: s} = resp} ->
        {:error, parse_error(s, resp)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch(:get, url, opts), do: Req.get(url, opts)
  defp dispatch(:post, url, opts), do: Req.post(url, opts)
  defp dispatch(:put, url, opts), do: Req.put(url, opts)
  defp dispatch(:patch, url, opts), do: Req.patch(url, opts)
  defp dispatch(:delete, url, opts), do: Req.delete(url, opts)

  defp parse_error(status, resp) do
    body = resp.body || %{}

    %Error{
      status: status,
      code: body["code"],
      message: body["message"] || default_message(status),
      request_id: get_header(resp, "x-request-id"),
      retry_after: parse_retry_after(get_header(resp, "retry-after"))
    }
  end

  defp get_header(resp, name) do
    case Enum.find(resp.headers, fn {k, _} -> String.downcase(k) == name end) do
      {_, v} -> v
      nil -> nil
    end
  end

  defp parse_retry_after(nil), do: nil

  defp parse_retry_after(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  @http_status_messages %{
    400 => "Bad Request",
    401 => "Unauthorized",
    403 => "Forbidden",
    404 => "Not Found",
    409 => "Conflict",
    422 => "Unprocessable Entity",
    429 => "Too Many Requests",
    500 => "Internal Server Error"
  }

  defp default_message(status), do: Map.get(@http_status_messages, status, "HTTP #{status}")

  defp verify_project_name(%{"name" => name}, name), do: :ok

  defp verify_project_name(%{"name" => actual}, confirm) do
    {:error,
     %Error{
       status: 0,
       message:
         "confirmation name #{inspect(confirm)} does not match project name #{inspect(actual)}"
     }}
  end

  # Merges router_ids from wrapper envelope into the breaker map
  defp flatten_breaker(%{"breaker" => breaker} = body) do
    case body["router_ids"] do
      nil -> breaker
      router_ids -> Map.put(breaker, "router_ids", router_ids)
    end
  end

  defp flatten_breaker(body), do: body

  defp build_list_params(opts) do
    []
    |> maybe_put(:cursor, opts[:cursor])
    |> maybe_put(:limit, opts[:limit])
    |> Map.new()
  end

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: [{key, value} | list]

  defp maybe_put_req(opts, _key, nil), do: opts
  defp maybe_put_req(opts, key, value), do: Keyword.put(opts, key, value)
end
