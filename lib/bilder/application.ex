defmodule Bilder.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        BilderWeb.Telemetry,
        Bilder.Repo,
        {DNSCluster, query: Application.get_env(:bilder, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Bilder.PubSub},
        {Task.Supervisor, name: Bilder.Biometrics.TaskSupervisor},
        Bilder.Biometrics.FaceRunner
      ] ++
        qwen_service_children() ++
        [
          # Start to serve requests, typically the last entry
          BilderWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Bilder.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BilderWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp qwen_service_children do
    if Application.get_env(:bilder, :start_qwen_service, true) do
      [Supervisor.child_spec({Bilder.QwenService, []}, shutdown: 10_000)]
    else
      []
    end
  end
end
