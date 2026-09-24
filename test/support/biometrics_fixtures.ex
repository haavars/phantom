defmodule Phantom.BiometricsFixtures do
  @moduledoc "Helpers for tests that need synthetic-biometrics runs on disk."

  @png <<137, 80, 78, 71, 13, 10, 26, 10>> <> "fake-png"

  def png, do: @png

  @doc """
  Stubs the Qwen service for the calling process (or globally, in shared
  `Req.Test` mode): ready on `GET /health`, a fake PNG for `POST /generate`.
  Pass `generate: fn conn -> ... end` to override the latter.
  """
  def stub_qwen(opts \\ []) do
    generate = Keyword.get(opts, :generate, &send_png/1)

    Req.Test.stub(Phantom.ImageGeneration, fn conn ->
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

  @doc """
  Stubs the friction-ridge service: ready on `GET /health`; `POST /render`
  returns a fake PNG with ground truth (a whorl with two minutiae), and reports
  `{:ridge_render, body}` to `notify` if given.

  Fingers and slaps come back verified: NFIQ 2 is 50 + code, finger 5 took two
  attempts and finger 7 was rejected. Their detected minutiae depend on seed and
  code only, and `POST /match` scores identical templates 250 and others 10, so
  captures of one finger are mated and anything else is not.
  """
  def stub_ridge(opts \\ []) do
    notify = Keyword.get(opts, :notify)

    Req.Test.stub(Phantom.Biometrics.FrictionRidge, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/health"} ->
          Req.Test.json(conn, %{status: "ready"})

        {"POST", "/render"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          body = Jason.decode!(body)
          if notify, do: send(notify, {:ridge_render, body})

          Req.Test.json(conn, %{
            image: Base.encode64(@png),
            width: 800,
            height: 750,
            ppi: 500,
            generator: "ridgegen/test",
            meta:
              Map.merge(
                %{
                  fgp: body["code"],
                  capture: body["capture"],
                  pattern: "whorl",
                  cores: [[400, 300], [410, 340]],
                  deltas: [[200, 600], [600, 610]],
                  minutiae_count: 2,
                  minutiae: [
                    %{x: 100, y: 120, angle: 45.0, type: "ending"},
                    %{x: 300, y: 320, angle: 180.0, type: "bifurcation"}
                  ]
                },
                verification_meta(body)
              )
          })

        {"POST", "/match"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          %{"templates" => templates, "pairs" => pairs} = Jason.decode!(body)

          scores =
            for [i, j] <- pairs,
                do: if(Enum.at(templates, i) == Enum.at(templates, j), do: 250, else: 10)

          Req.Test.json(conn, %{scores: scores})
      end
    end)
  end

  defp verification_meta(%{"kind" => kind, "code" => code, "seed" => seed})
       when kind in ["finger", "slap"] do
    attempts = %{5 => 2, 7 => 3}[code] || 1

    %{
      impression: if(kind == "finger", do: "rolled", else: "plain"),
      verification: %{
        renderer: "procedural",
        attempts: attempts,
        attempt: attempts - 1,
        accepted: code != 7,
        nfiq2: 50 + code,
        minutiae_recall: 0.97,
        minutiae_spurious: 0.02,
        mean_displacement_px: 0.7,
        missed: [[10, 20]],
        spurious: [],
        detected: [[rem(seed, 500), code * 10, 90, 60], [300, 320, 180, 50]]
      }
    }
  end

  defp verification_meta(_body), do: %{}

  @doc """
  Creates a run with the stubbed services and returns its name. Names are
  unique by default, since every test shares the storage root
  (`config :phantom, :biometrics_output_dir`).
  """
  def create_run(opts \\ []) do
    stub_qwen()
    stub_ridge()

    opts =
      Keyword.merge(
        [
          run: unique_run_name(),
          seed: 42,
          subjects: 2,
          shots: ["mugshot_left_profile"]
        ],
        opts
      )

    {:ok, _result} = Phantom.Biometrics.Harness.run(opts)
    Keyword.fetch!(opts, :run)
  end

  @doc "A run name no other test uses."
  def unique_run_name(prefix \\ "run"), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
