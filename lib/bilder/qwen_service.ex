defmodule Bilder.QwenService do
  @moduledoc """
  Runs the local Qwen-Image-2.1 inference process (`python_inference/server.py`)
  as a supervised part of this application: `mix phx.server` starts it and app
  shutdown stops it, so there's no separate process to manage by hand.

  Requires the one-time setup in `python_inference/README.md` (a venv with the
  model's dependencies installed). If that hasn't been done yet, this logs a
  warning and the app still boots normally — `Bilder.ImageGeneration` will
  surface a clear "couldn't reach the service" error until setup is done.

  Disable auto-start (e.g. to run the model on another machine) by setting
  `QWEN_AUTOSTART=false`, and point the app at it with `QWEN_SERVICE_URL`.
  """

  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    dir = Application.fetch_env!(:bilder, :qwen_service_dir)

    case python_executable(dir) do
      {:ok, python} ->
        port =
          Port.open({:spawn_executable, String.to_charlist(python)}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"server.py"],
            cd: String.to_charlist(dir),
            env: [{~c"PYTHONUNBUFFERED", ~c"1"}]
          ])

        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            nil -> nil
          end

        Logger.info(
          "[qwen-image] starting inference service (os pid #{inspect(os_pid)}) from #{dir}"
        )

        {:ok, %{port: port, os_pid: os_pid}}

      {:error, reason} ->
        Logger.warning("[qwen-image] not auto-starting inference service: #{reason}")
        {:ok, %{port: nil, os_pid: nil}}
    end
  end

  defp python_executable(dir) do
    venv_python = Path.join([dir, ".venv", "bin", "python"])

    cond do
      File.exists?(venv_python) ->
        {:ok, venv_python}

      python3 = System.find_executable("python3") ->
        Logger.warning(
          "[qwen-image] #{venv_python} not found, falling back to system python3 (#{python3}). " <>
            "Run the one-time setup in python_inference/README.md if generation fails."
        )

        {:ok, python3}

      true ->
        {:error, "no python interpreter found (looked for #{venv_python} and python3 on PATH)"}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    for line <- String.split(data, "\n", trim: true), do: Logger.info("[qwen-image] #{line}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("[qwen-image] inference service exited (status #{status})")
    {:noreply, %{state | port: nil, os_pid: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{os_pid: nil}), do: :ok

  def terminate(_reason, %{os_pid: os_pid}) do
    Logger.info("[qwen-image] stopping inference service (os pid #{os_pid})")
    System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end
end
