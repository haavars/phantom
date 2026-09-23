defmodule BilderWeb.BiometricsLiveTest do
  # Uses the global face output dir and the app-wide Runner.
  use BilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bilder.BiometricsFixtures

  alias Bilder.Biometrics.Runner

  @moduletag :tmp_dir

  setup {Req.Test, :set_req_test_to_shared}

  setup %{tmp_dir: root} do
    use_output_dir(root)
    stub_qwen()
    stub_ridge()
    on_exit(fn -> Runner.cancel() end)
    :ok
  end

  test "renders the form and an empty runs list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/biometrics")

    assert has_element?(view, "#batch-form")
    assert has_element?(view, "#shot-mugshot_frontal")
    assert has_element?(view, "#group-rolled[checked]")
    assert has_element?(view, "#batch_captures")
    assert has_element?(view, "#runs-empty")
    assert has_element?(view, "#nav-biometrics")
  end

  test "lists existing runs", %{conn: conn, tmp_dir: root} do
    run = create_run(root)
    {:ok, view, _html} = live(conn, ~p"/biometrics")

    assert has_element?(view, ~s(#runs-#{run}[href="/biometrics/#{run}"]))
    refute has_element?(view, "#runs-empty")
  end

  test "validates the form and updates the estimate", %{conn: conn, tmp_dir: root} do
    run = create_run(root)
    {:ok, view, _html} = live(conn, ~p"/biometrics")

    view
    |> form("#batch-form", batch: %{subjects: "0", run: run})
    |> render_change()

    assert has_element?(view, "#batch-form", "must be greater than or equal to 1")
    assert has_element?(view, "#batch-form", "already exists")

    view
    |> form("#batch-form", batch: %{subjects: "2", run: "", shots: ["", "probe_aged"]})
    |> render_change()

    assert has_element?(view, "#run-estimate", "4 images")
  end

  test "starts a run and navigates to it", %{conn: conn, tmp_dir: root} do
    Runner.subscribe()
    {:ok, view, _html} = live(conn, ~p"/biometrics")

    assert {:error, {:live_redirect, %{to: "/biometrics/ui-run"}}} =
             view
             |> form("#batch-form",
               batch: %{subjects: "1", run: "ui-run", shots: ["", "rolled"]}
             )
             |> render_submit()

    assert_receive {:biometrics_run, :finished, %{run: "ui-run"}}
    assert File.exists?(Path.join([root, "ui-run", "subject_001", "rolled_10.png"]))
    refute File.exists?(Path.join([root, "ui-run", "subject_001", "mugshot_frontal.png"]))
  end

  test "shows the active run while it renders and cancels it", %{conn: conn, tmp_dir: root} do
    test_pid = self()

    stub_qwen(
      generate: fn conn ->
        send(test_pid, :rendering)

        receive do
          :continue -> send_png(conn)
        end
      end
    )

    Runner.subscribe()
    {:ok, view, _html} = live(conn, ~p"/biometrics")
    {:ok, "busy-run"} = Runner.start_run(out: root, run: "busy-run", subjects: 1)
    assert_receive :rendering

    assert has_element?(view, "#active-run", "busy-run")
    assert has_element?(view, "#start-run[disabled]")

    view |> element("#cancel-run") |> render_click()
    assert_receive {:biometrics_run, :cancelled, _progress}
    refute has_element?(view, "#active-run")
  end
end
