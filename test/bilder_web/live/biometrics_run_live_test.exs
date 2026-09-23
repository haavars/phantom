defmodule BilderWeb.BiometricsRunLiveTest do
  # Uses the global face output dir and the app-wide Runner.
  use BilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bilder.BiometricsFixtures

  alias Bilder.Biometrics.Runner

  @moduletag :tmp_dir

  setup {Req.Test, :set_req_test_to_shared}

  setup %{tmp_dir: root} do
    use_output_dir(root)
    on_exit(fn -> Runner.cancel() end)
    {:ok, run: create_run(root)}
  end

  test "shows every subject with its shots", %{conn: conn, run: run} do
    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}")

    assert has_element?(view, "#run-meta", "42")
    assert has_element?(view, "#subjects-subject_001")
    assert has_element?(view, "#subjects-subject_002")
    assert has_element?(view, "#tile-subject_001-mugshot_frontal img")
    assert has_element?(view, "#tile-subject_002-mugshot_left_profile img")
    refute has_element?(view, "#resume-run")
  end

  test "opens a shot in the detail view and moves between shots", %{conn: conn, run: run} do
    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}")

    view |> element("#tile-subject_001-mugshot_frontal a") |> render_click()

    assert_patch(
      view,
      ~p"/biometrics/#{run}?#{[subject: "subject_001", shot: "mugshot_frontal"]}"
    )

    assert has_element?(view, "#shot-detail")
    assert has_element?(view, "#shot-prompt", "Police booking photograph")
    refute has_element?(view, "#prev-shot")

    view |> element("#next-shot") |> render_click()

    assert_patch(
      view,
      ~p"/biometrics/#{run}?#{[subject: "subject_001", shot: "mugshot_left_profile"]}"
    )

    assert has_element?(view, "#shot-prompt", "left profile")

    view |> element("#shot-detail") |> render_keydown(%{"key" => "ArrowLeft"})

    assert_patch(
      view,
      ~p"/biometrics/#{run}?#{[subject: "subject_001", shot: "mugshot_frontal"]}"
    )

    view |> element("#shot-detail") |> render_keydown(%{"key" => "Escape"})
    assert_patch(view, ~p"/biometrics/#{run}")
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
    Runner.subscribe()
    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}")
    refute has_element?(view, "#subjects-subject_003")

    view |> element("#resume-run") |> render_click()
    assert_receive {:biometrics_run, :finished, %{run: ^run}}

    assert has_element?(view, "#tile-subject_003-mugshot_left_profile img")
    refute has_element?(view, "#resume-run")
  end

  test "redirects to the run list for unknown runs", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/biometrics"}}} = live(conn, ~p"/biometrics/missing")
  end

  test "groups friction-ridge shots and shows their ground truth", %{conn: conn, tmp_dir: root} do
    run =
      create_run(root, run: "ridge-run", subjects: 1, shots: ["mugshot_left_profile", "rolled"])

    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}")

    assert has_element?(view, "#subject_001-face-0")
    assert has_element?(view, "#subject_001-rolled-0", "Rolled fingers")
    assert has_element?(view, "#tile-subject_001-rolled_03 img")
    assert has_element?(view, "#tile-subject_001-rolled_03", "W")

    view |> element("#tile-subject_001-rolled_03 a") |> render_click()
    assert has_element?(view, "#ridge-meta", "whorl")
    assert has_element?(view, "#ridge-meta", "2 cores, 2 deltas")
    assert has_element?(view, ~s(#ground-truth-link[href$="/subject_001/rolled_03.json"]))
    refute has_element?(view, "#shot-prompt")
  end

  test "opens a face shot of the subject that is still rendering", %{conn: conn, tmp_dir: root} do
    test_pid = self()

    # The anchor renders; the next shot blocks, so the run stays active with a
    # subject that only exists in the runner's progress, not on disk.
    stub_qwen(
      generate: fn conn ->
        conn =
          Plug.Parsers.call(
            conn,
            Plug.Parsers.init(parsers: [Plug.Parsers.MULTIPART], length: 20_000_000)
          )

        if conn.params["images"] do
          send(test_pid, :rendering)

          receive do
            :continue -> send_png(conn)
          end
        else
          send_png(conn)
        end
      end
    )

    Runner.subscribe()

    {:ok, "live-run"} =
      Runner.start_run(out: root, run: "live-run", subjects: 1, shots: ["mugshot_left_profile"])

    assert_receive :rendering

    {:ok, view, _html} =
      live(conn, ~p"/biometrics/live-run?#{[subject: "subject_001", shot: "mugshot_frontal"]}")

    assert has_element?(view, "#shot-detail")
    assert has_element?(view, "#shot-prompt", "Police booking photograph")
    refute has_element?(view, "#ridge-meta")
  end
end
