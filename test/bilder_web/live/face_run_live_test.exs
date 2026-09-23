defmodule BilderWeb.FaceRunLiveTest do
  # Uses the global face output dir and the app-wide FaceRunner.
  use BilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bilder.FaceFixtures

  alias Bilder.Biometrics.FaceRunner

  @moduletag :tmp_dir

  setup {Req.Test, :set_req_test_to_shared}

  setup %{tmp_dir: root} do
    use_face_output_dir(root)
    on_exit(fn -> FaceRunner.cancel() end)
    {:ok, run: create_face_run(root)}
  end

  test "shows every subject with its shots", %{conn: conn, run: run} do
    {:ok, view, _html} = live(conn, ~p"/faces/#{run}")

    assert has_element?(view, "#run-meta", "42")
    assert has_element?(view, "#subjects-subject_001")
    assert has_element?(view, "#subjects-subject_002")
    assert has_element?(view, "#tile-subject_001-mugshot_frontal img")
    assert has_element?(view, "#tile-subject_002-mugshot_left_profile img")
    refute has_element?(view, "#resume-run")
  end

  test "opens a shot in the detail view and moves between shots", %{conn: conn, run: run} do
    {:ok, view, _html} = live(conn, ~p"/faces/#{run}")

    view |> element("#tile-subject_001-mugshot_frontal a") |> render_click()
    assert_patch(view, ~p"/faces/#{run}?#{[subject: "subject_001", shot: "mugshot_frontal"]}")
    assert has_element?(view, "#shot-detail")
    assert has_element?(view, "#shot-prompt", "Police booking photograph")
    refute has_element?(view, "#prev-shot")

    view |> element("#next-shot") |> render_click()

    assert_patch(
      view,
      ~p"/faces/#{run}?#{[subject: "subject_001", shot: "mugshot_left_profile"]}"
    )

    assert has_element?(view, "#shot-prompt", "left profile")

    view |> element("#shot-detail") |> render_keydown(%{"key" => "ArrowLeft"})
    assert_patch(view, ~p"/faces/#{run}?#{[subject: "subject_001", shot: "mugshot_frontal"]}")

    view |> element("#shot-detail") |> render_keydown(%{"key" => "Escape"})
    assert_patch(view, ~p"/faces/#{run}")
    refute has_element?(view, "#shot-detail")
  end

  test "resumes an incomplete run and shows new subjects live", %{
    conn: conn,
    run: run,
    tmp_dir: root
  } do
    # Pretend the run was meant to have a third subject.
    run_json = Path.join([root, run, "run.json"])
    config = run_json |> File.read!() |> Jason.decode!()
    File.write!(run_json, Jason.encode!(%{config | "subjects" => 3}))

    stub_qwen()
    FaceRunner.subscribe()
    {:ok, view, _html} = live(conn, ~p"/faces/#{run}")
    refute has_element?(view, "#subjects-subject_003")

    view |> element("#resume-run") |> render_click()
    assert_receive {:face_run, :finished, %{run: ^run}}

    assert has_element?(view, "#tile-subject_003-mugshot_left_profile img")
    refute has_element?(view, "#resume-run")
  end

  test "redirects to the run list for unknown runs", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/faces"}}} = live(conn, ~p"/faces/missing")
  end
end
