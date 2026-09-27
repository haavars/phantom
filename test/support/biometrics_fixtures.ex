defmodule Phantom.BiometricsFixtures do
  @moduledoc "Helpers for tests that need synthetic-biometrics runs: service stubs and rendered runs."

  @png <<137, 80, 78, 71, 13, 10, 26, 10>> <> "fake-png"

  def png, do: @png

  @doc """
  Stubs the Qwen service for the calling process (or globally, in shared
  `Req.Test` mode): ready on `GET /health`, a fake PNG for `POST /generate`.
  Pass `generate: fn conn -> ... end` to override the latter.
  """
  def stub_qwen(opts \\ []) do
    generate = Keyword.get(opts, :generate, &send_png/1)

    Req.Test.stub(Phantom.Services.Qwen, fn conn ->
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

  `POST /face/embed` finds one face, with a template that's a different basis
  vector on every call, so any two anchors score 0 and pass the face gate.
  Pass `embed: fn -> response end` to return other JSON (built with
  `face_template/3`), or `{status, body}` for an HTTP error.
  """
  def stub_ridge(opts \\ []) do
    notify = Keyword.get(opts, :notify)
    embed = Keyword.get(opts, :embed, &stranger/0)

    Req.Test.stub(Phantom.Services.Ridgegen, fn conn ->
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

        {"POST", "/face/embed"} ->
          case embed.() do
            {status, body} -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
            body -> Req.Test.json(conn, body)
          end
      end
    end)
  end

  defp stranger do
    axis = rem(System.unique_integer([:positive, :monotonic]), 512)
    %{faces: 1, det: 0.9, template: face_template(axis)}
  end

  @doc """
  A base64 template, as `POST /face/embed` returns it: unit vectors along
  `axis` (0-511), mixed with `similarity` of `base` when given, so it scores
  `similarity` against `face_template(base)`.
  """
  def face_template(axis, base \\ nil, similarity \\ 0.0) do
    other = :math.sqrt(1 - similarity * similarity)

    for i <- 0..511, into: <<>> do
      value =
        cond do
          i == base -> similarity
          i == axis -> if(base, do: other, else: 1.0)
          true -> 0.0
        end

      <<value::little-float-32>>
    end
    |> Base.encode64()
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
  Creates a run with the stubbed services, renders it by draining the Oban
  queue in the test process, and returns its name. Names are unique by
  default, since every test shares the storage root
  (`config :phantom, :biometrics_output_dir`).
  """
  def create_run(params \\ []) do
    stub_qwen()
    stub_ridge()

    params =
      Map.merge(
        %{run: unique_run_name(), seed: 42, subjects: 2, shots: ["mugshot_left_profile"]},
        Map.new(params)
      )

    {:ok, run} = Phantom.Biometrics.create_run(params)
    render_queued()
    run.name
  end

  @doc "Runs every queued subject job in the test process."
  def render_queued do
    Oban.drain_queue(queue: :generation, with_safety: false)
  end

  @doc """
  Renders the queued jobs in a separate process, for tests that look at a
  run while it renders (with a stub that blocks). Needs the shared sandbox and
  `Req.Test` modes, i.e. an `async: false` test.
  """
  def render_queued_async, do: Task.async(&render_queued/0)

  @doc "A run name no other test uses."
  def unique_run_name(prefix \\ "run"), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
