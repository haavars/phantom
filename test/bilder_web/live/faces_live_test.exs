defmodule BilderWeb.FacesLiveTest do
  # Uses the global face output dir and the app-wide FaceRunner.
  use BilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bilder.FaceFixtures

  alias Bilder.Biometrics.FaceRunner

  @moduletag :tmp_dir

  setup {Req.Test, :set_req_test_to_shared}

  setup %{tmp_dir: root} do
    use_face_output_dir(root)
    stub_qwen()
    on_exit(fn -> FaceRunner.cancel() end)
    :ok
  end

  test "renders the form and an empty runs list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/faces")

    assert has_element?(view, "#face-run-form")
    assert has_element?(view, "#shot-mugshot_frontal[disabled]")
    assert has_element?(view, "#runs-empty")
    assert has_element?(view, "#nav-faces")
  end

  test "lists existing runs", %{conn: conn, tmp_dir: root} do
    run = create_face_run(root)
    {:ok, view, _html} = live(conn, ~p"/faces")

    assert has_element?(view, ~s(#runs-#{run}[href="/faces/#{run}"]))
    refute has_element?(view, "#runs-empty")
  end

  test "validates the form and updates the estimate", %{conn: conn, tmp_dir: root} do
    run = create_face_run(root)
    {:ok, view, _html} = live(conn, ~p"/faces")

    view
    |> form("#face-run-form", face_run: %{subjects: "0", run: run})
    |> render_change()

    assert has_element?(view, "#face-run-form", "must be greater than or equal to 1")
    assert has_element?(view, "#face-run-form", "already exists")

    view
    |> form("#face-run-form", face_run: %{subjects: "2", run: "", shots: ["", "probe_aged"]})
    |> render_change()

    assert has_element?(view, "#run-estimate", "4 images")
  end

  test "starts a run and navigates to it", %{conn: conn, tmp_dir: root} do
    FaceRunner.subscribe()
    {:ok, view, _html} = live(conn, ~p"/faces")

    assert {:error, {:live_redirect, %{to: "/faces/ui-run"}}} =
             view
             |> form("#face-run-form", face_run: %{subjects: "1", run: "ui-run", shots: [""]})
             |> render_submit()

    assert_receive {:face_run, :finished, %{run: "ui-run"}}
    assert File.exists?(Path.join([root, "ui-run", "subject_001", "mugshot_frontal.png"]))
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

    FaceRunner.subscribe()
    {:ok, view, _html} = live(conn, ~p"/faces")
    {:ok, "busy-run"} = FaceRunner.start_run(out: root, run: "busy-run", subjects: 1)
    assert_receive :rendering

    assert has_element?(view, "#active-run", "busy-run")
    assert has_element?(view, "#start-run[disabled]")

    view |> element("#cancel-run") |> render_click()
    assert_receive {:face_run, :cancelled, _progress}
    refute has_element?(view, "#active-run")
  end
end
