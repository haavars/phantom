defmodule Phantom.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        PhantomWeb.Telemetry,
        Phantom.Repo,
        {DNSCluster, query: Application.get_env(:phantom, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Phantom.PubSub},
        {Oban, Application.fetch_env!(:phantom, Oban)}
      ] ++
        python_services() ++
        [
          # Start to serve requests, typically the last entry
          PhantomWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Phantom.Supervisor]

    Phantom.Biometrics.Workers.GenerateSubject.attach_telemetry()
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PhantomWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # The local Python services, unless disabled (e.g. because they run on
  # another machine, or in tests).
  defp python_services do
    [
      {:start_qwen_service, Phantom.Services.QwenProcess, "qwen-image", :qwen_service_dir,
       :qwen_service_url},
      {:start_biometrics_service, Phantom.Services.RidgegenProcess, "ridgegen",
       :biometrics_service_dir, :biometrics_service_url}
    ]
    |> Enum.filter(fn {enabled_key, _name, _label, _dir_key, _url_key} ->
      Application.get_env(:phantom, enabled_key, true)
    end)
    |> Enum.map(fn {_enabled_key, name, label, dir_key, url_key} ->
      {Phantom.Services.PythonProcess,
       name: name,
       label: label,
       dir: Application.fetch_env!(:phantom, dir_key),
       url: Application.fetch_env!(:phantom, url_key)}
    end)
  end
end
