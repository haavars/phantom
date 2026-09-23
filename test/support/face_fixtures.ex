defmodule Bilder.FaceFixtures do
  @moduledoc "Helpers for tests that need synthetic-face runs on disk."

  @png <<137, 80, 78, 71, 13, 10, 26, 10>> <> "fake-png"

  def png, do: @png

  @doc """
  Stubs the Qwen service for the calling process (or globally, in shared
  `Req.Test` mode): ready on `GET /health`, a fake PNG for `POST /generate`.
  Pass `generate: fn conn -> ... end` to override the latter.
  """
  def stub_qwen(opts \\ []) do
    generate = Keyword.get(opts, :generate, &send_png/1)

    Req.Test.stub(Bilder.ImageGeneration, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/health"} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{status: "ready"}))

        {"POST", "/generate"} ->
          generate.(conn)
      end
    end)
  end

  def send_png(conn) do
    conn
    |> Plug.Conn.put_resp_header("x-seed", "1")
    |> Plug.Conn.put_resp_content_type("image/png")
    |> Plug.Conn.send_resp(200, @png)
  end

  @doc "Creates a run under `root` with the stubbed service. Returns its name."
  def create_face_run(root, opts \\ []) do
    stub_qwen()

    opts =
      Keyword.merge(
        [out: root, run: "fixture-run", seed: 42, subjects: 2, shots: ["mugshot_left_profile"]],
        opts
      )

    {:ok, _result} = Bilder.Biometrics.FaceHarness.run(opts)
    Keyword.fetch!(opts, :run)
  end

  @doc """
  Points `:face_output_dir` at `root` for the rest of the test. The setting is
  global, so only use this from `async: false` tests.
  """
  def use_face_output_dir(root) do
    previous = Application.get_env(:bilder, :face_output_dir)
    Application.put_env(:bilder, :face_output_dir, root)
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:bilder, :face_output_dir, previous) end)
  end
end
