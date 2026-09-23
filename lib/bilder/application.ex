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
        Bilder.Biometrics.Runner
      ] ++
        python_services() ++
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

  # The local Python services, unless disabled (e.g. because they run on
  # another machine, or in tests).
  defp python_services do
    [
      {:start_qwen_service, Bilder.QwenService, "qwen-image", :qwen_service_dir,
       :qwen_service_url},
      {:start_biometrics_service, Bilder.BiometricsService, "biometrics", :biometrics_service_dir,
       :biometrics_service_url}
    ]
    |> Enum.filter(fn {enabled_key, _name, _label, _dir_key, _url_key} ->
      Application.get_env(:bilder, enabled_key, true)
    end)
    |> Enum.map(fn {_enabled_key, name, label, dir_key, url_key} ->
      {Bilder.PythonService,
       name: name,
       label: label,
       dir: Application.fetch_env!(:bilder, dir_key),
       url: Application.fetch_env!(:bilder, url_key)}
    end)
  end
end
