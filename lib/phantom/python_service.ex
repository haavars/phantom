defmodule Phantom.PythonService do
  @moduledoc """
  Runs a local Python service (a `server.py` in its own venv) as a supervised
  part of this application: `mix phx.server` starts it, restarts it if it dies,
  and stops it on shutdown, so there's no separate process to manage by hand.
  Used for:

    * `Phantom.QwenService` - Qwen-Image-2.1 (`python_inference/`, GPU, port 8000)
    * `Phantom.BiometricsService` - synthetic friction ridges (`python_biometrics/`, CPU, port 8001)

  The service runs as an OS process behind an Erlang port rather than inside
  the BEAM: a crash or out-of-memory error in PyTorch/CUDA then takes down only
  the service, which gets restarted, not the whole Phoenix app.

  Lifecycle details:

    * The service exits when this app goes away, even abruptly (Ctrl+C twice
      skips shutdown code): it watches its stdin pipe from the port, which
      closes when the BEAM exits (`exit_with_parent` in each `server.py`).
    * If something already listens on the service's port (a leftover copy, or
      one started by hand), this logs that and uses it instead of starting a
      second copy that couldn't bind, and checks again later.
    * If the service exits, it is restarted after a backoff (5 s doubling up
      to 60 s).

  Each service needs the one-time setup in its directory's README. Without it
  this logs a warning and the app still boots; the HTTP clients report the
  service as unreachable.

  Options: `:name` (registered name and child id), `:label` (log prefix),
  `:dir` (the service directory), `:url` (base URL, for the port check),
  `:script` (default `server.py`) and `:initial_backoff` (ms, default 5000).
  """

  use GenServer
  require Logger

  @initial_backoff :timer.seconds(5)
  @max_backoff :timer.seconds(60)

  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :name),
      start: {__MODULE__, :start_link, [opts]},
      # Give the Python process time to shut down cleanly.
      shutdown: 10_000
    }
  end

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      dir: Keyword.fetch!(opts, :dir),
      label: Keyword.fetch!(opts, :label),
      script: Keyword.get(opts, :script, "server.py"),
      url: Keyword.get(opts, :url),
      port: nil,
      os_pid: nil,
      initial_backoff: Keyword.get(opts, :initial_backoff, @initial_backoff),
      backoff: Keyword.get(opts, :initial_backoff, @initial_backoff),
      started_at: nil,
      external?: false
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state), do: {:noreply, start(state)}

  defp start(state) do
    with :free <- port_status(state.url),
         {:ok, python} <- python_executable(state) do
      port =
        Port.open({:spawn_executable, String.to_charlist(python)}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [String.to_charlist(state.script)],
          cd: String.to_charlist(state.dir),
          # The port's stdin pipe closes when the BEAM exits; the service exits then.
          env: [{~c"PYTHONUNBUFFERED", ~c"1"}, {~c"PHANTOM_EXIT_WITH_PARENT", ~c"1"}]
        ])

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          nil -> nil
        end

      Logger.info(
        "[#{state.label}] starting service (os pid #{inspect(os_pid)}) from #{state.dir}"
      )

      %{
        state
        | port: port,
          os_pid: os_pid,
          external?: false,
          started_at: System.monotonic_time(:millisecond)
      }
    else
      {:in_use, address} ->
        unless state.external? do
          Logger.warning(
            "[#{state.label}] #{address} is already in use, so not starting another copy; " <>
              "using the service that's already running there. If it's a leftover from an " <>
              "earlier run, stop it (`kill $(lsof -ti tcp:#{port_of(address)})`) and this app " <>
              "will start and manage its own copy."
          )
        end

        # Check again later, so a stopped leftover gets replaced by a managed copy.
        Process.send_after(self(), :start, @max_backoff)
        %{state | external?: true}

      {:error, reason} ->
        Logger.warning("[#{state.label}] not auto-starting service: #{reason}")
        state
    end
  end

  # :free, or {:in_use, "host:port"} when something already accepts connections there.
  defp port_status(nil), do: :free

  defp port_status(url) do
    %URI{host: host, port: port} = URI.parse(url)

    case :gen_tcp.connect(String.to_charlist(host), port, [], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        {:in_use, "#{host}:#{port}"}

      {:error, _reason} ->
        :free
    end
  end

  defp port_of(address), do: address |> String.split(":") |> List.last()

  defp python_executable(%{dir: dir, label: label}) do
    venv_python = Path.join([dir, ".venv", "bin", "python"])

    cond do
      File.exists?(venv_python) ->
        {:ok, venv_python}

      python3 = System.find_executable("python3") ->
        Logger.warning(
          "[#{label}] #{venv_python} not found, falling back to system python3 (#{python3}). " <>
            "Run the one-time setup in #{dir}/README.md if the service fails."
        )

        {:ok, python3}

      true ->
        {:error, "no python interpreter found (looked for #{venv_python} and python3 on PATH)"}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    for line <- String.split(data, "\n", trim: true), do: Logger.info("[#{state.label}] #{line}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    # A service that ran for a while before dying starts the backoff afresh.
    uptime = System.monotonic_time(:millisecond) - state.started_at

    state =
      if uptime > @max_backoff * 2, do: %{state | backoff: state.initial_backoff}, else: state

    Logger.error(
      "[#{state.label}] service exited (status #{status}), restarting in #{div(state.backoff, 1000)} s"
    )

    Process.send_after(self(), :start, state.backoff)

    {:noreply, %{state | port: nil, os_pid: nil, backoff: min(state.backoff * 2, @max_backoff)}}
  end

  def handle_info(:start, %{port: nil} = state), do: {:noreply, start(state)}

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{os_pid: nil}), do: :ok

  def terminate(_reason, %{os_pid: os_pid, label: label}) do
    Logger.info("[#{label}] stopping service (os pid #{os_pid})")
    System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end
end
