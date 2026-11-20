defmodule SaasExample.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    SaasExample.Security.verify_runtime_config!()

    children = [
      SaasExample.Repo,
      SaasExampleWeb.Telemetry,
      SaasExampleWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: SaasExample.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    SaasExampleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
