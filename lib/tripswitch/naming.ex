defmodule Tripswitch.Naming do
  @moduledoc false

  # Each named Tripswitch.Client supervisor registers its children under
  # {client_name, role} keys in Tripswitch.Registry.

  def via(client_name, role) do
    {:via, Registry, {Tripswitch.Registry, {client_name, role}}}
  end

  def state_server(name), do: via(name, :state_server)
  def sse_listener(name), do: via(name, :sse_listener)
  def flusher(name), do: via(name, :flusher)
  def metadata_cache(name), do: via(name, :metadata_cache)
end
