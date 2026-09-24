defmodule Phantom.PythonServiceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Phantom.PythonService

  @moduletag :tmp_dir

  # A stand-in for a venv python: records that it started, then blocks on stdin
  # the way the real services do until the app goes away.
  defp fake_service(dir) do
    python = Path.join([dir, ".venv", "bin", "python"])
    File.mkdir_p!(Path.dirname(python))
    File.write!(python, "#!/bin/sh\necho started >> #{Path.join(dir, "starts.log")}\nexec cat\n")
    File.chmod!(python, 0o755)
  end

  defp starts(dir) do
    case File.read(Path.join(dir, "starts.log")) do
      {:ok, log} -> log |> String.split("\n", trim: true) |> length()
      {:error, _reason} -> 0
    end
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> receive(after: (10 -> wait_until(fun, attempts - 1)))
    end
  end

  test "starts the service, restarts it when it dies, and stops it on shutdown", %{tmp_dir: dir} do
    fake_service(dir)

    name = :"svc_#{System.unique_integer([:positive])}"

    capture_log(fn ->
      pid =
        start_supervised!(
          {PythonService, name: name, label: "test", dir: dir, initial_backoff: 10}
        )

      wait_until(fn -> starts(dir) == 1 end)
      %{os_pid: first} = :sys.get_state(pid)

      System.cmd("kill", ["-KILL", Integer.to_string(first)])
      wait_until(fn -> starts(dir) == 2 end)
      wait_until(fn -> :sys.get_state(pid).os_pid not in [nil, first] end)
      %{os_pid: second} = :sys.get_state(pid)

      # The child id is the service name.
      :ok = stop_supervised!(name)

      {_output, status} =
        System.cmd("kill", ["-0", Integer.to_string(second)], stderr_to_stdout: true)

      assert status != 0
    end)
  end

  test "uses a service that already listens on the port instead of starting a copy", %{
    tmp_dir: dir
  } do
    fake_service(dir)
    {:ok, listener} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listener)

    log =
      capture_log(fn ->
        pid =
          start_supervised!(
            {PythonService,
             name: :"svc_#{System.unique_integer([:positive])}",
             label: "test",
             dir: dir,
             url: "http://127.0.0.1:#{port}"}
          )

        assert %{external?: true, os_pid: nil} = :sys.get_state(pid)
      end)

    assert log =~ "already in use"
    assert starts(dir) == 0
  end
end
