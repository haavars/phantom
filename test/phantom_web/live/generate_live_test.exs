defmodule PhantomWeb.GenerateLiveTest do
  use PhantomWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @fake_png <<137, 80, 78, 71, 13, 10, 26, 10>> <> "not-a-real-png-but-good-enough-for-tests"

  setup do
    # The LiveView polls GET /health on mount (Phantom.Services.QwenProcess itself isn't
    # started in tests, see config/test.exs), so every test needs a stub for
    # it regardless of what it's testing. Individual tests can call
    # Req.Test.stub/2 again to also handle POST /generate.
    Req.Test.stub(Phantom.Services.Qwen, &stub_ready/1)
    :ok
  end

  defp stub_ready(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{status: "ready"}))
  end

  test "renders the prompt form", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, PhantomWeb.GenerateLive)

    assert html =~ "Phantom"
    assert html =~ ~s(id="generate-form")
  end

  test "shows an error when submitting a blank prompt", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, PhantomWeb.GenerateLive)

    html =
      view
      |> form("#generate-form",
        generation: %{"prompt" => "", "aspect_ratio" => "1:1", "steps" => "40", "seed" => ""}
      )
      |> render_submit()

    assert html =~ "Please enter a prompt."
  end

  test "generates and displays an image for a valid prompt", %{conn: conn} do
    Req.Test.stub(Phantom.Services.Qwen, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/health"} ->
          stub_ready(conn)

        {"POST", "/generate"} ->
          conn
          |> Plug.Conn.put_resp_header("x-seed", "42")
          |> Plug.Conn.put_resp_content_type("image/png")
          |> Plug.Conn.send_resp(200, @fake_png)
      end
    end)

    {:ok, view, _html} = live_isolated(conn, PhantomWeb.GenerateLive)

    # The self-sent :check_service_status message (from mount) is enqueued
    # in the view's mailbox before `live/2` above even returns, so this
    # round-trip is guaranteed to observe it having been handled already,
    # meaning nothing (in particular, not the Generate button) is disabled.
    refute render(view) =~ "disabled"

    view
    |> form("#generate-form",
      generation: %{
        "prompt" => "a red bicycle",
        "aspect_ratio" => "1:1",
        "steps" => "20",
        "seed" => ""
      }
    )
    |> render_submit()

    html = render_async(view)

    assert html =~ "a red bicycle"
    assert html =~ "seed: 42"
  end

  test "attaches a selected reference image to the generation request", %{conn: conn} do
    Req.Test.stub(Phantom.Services.Qwen, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/health"} ->
          stub_ready(conn)

        {"POST", "/generate"} ->
          conn =
            Plug.Parsers.call(
              conn,
              Plug.Parsers.init(parsers: [Plug.Parsers.MULTIPART], length: 20_000_000)
            )

          assert [%Plug.Upload{filename: "hat.png"}] = List.wrap(conn.params["images"])

          conn
          |> Plug.Conn.put_resp_header("x-seed", "9")
          |> Plug.Conn.put_resp_content_type("image/png")
          |> Plug.Conn.send_resp(200, @fake_png)
      end
    end)

    {:ok, view, _html} = live_isolated(conn, PhantomWeb.GenerateLive)
    refute render(view) =~ "disabled"

    reference =
      file_input(view, "#generate-form", :reference_images, [
        %{name: "hat.png", content: @fake_png, type: "image/png"}
      ])

    assert render_upload(reference, "hat.png") =~ "Remove hat.png"

    view
    |> form("#generate-form",
      generation: %{
        "prompt" => "put the hat on the cat",
        "aspect_ratio" => "1:1",
        "steps" => "20",
        "seed" => ""
      }
    )
    |> render_submit()

    html = render_async(view)

    assert html =~ "put the hat on the cat"
    assert html =~ "seed: 9"
  end

  test "shows an error for oversized reference images", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, PhantomWeb.GenerateLive)
    refute render(view) =~ "disabled"

    too_big = :binary.copy(<<0>>, 16_000_000)

    reference =
      file_input(view, "#generate-form", :reference_images, [
        %{name: "huge.png", content: too_big, type: "image/png"}
      ])

    assert {:error, [[_ref, :too_large]]} = render_upload(reference, "huge.png")
    assert render(view) =~ "is too large"
  end
end
