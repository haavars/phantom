defmodule PhantomWeb.BiometricsRunLiveTest do
  # Uses the global face output dir and the app-wide Runner.
  use PhantomWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Phantom.BiometricsFixtures

  alias Phantom.Biometrics.Runner

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

  test "shows one identity with all of its images", %{conn: conn, run: run} do
    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}/subject_002")

    assert has_element?(view, "#identity-header")
    assert has_element?(view, ~s(#back-to-run[href="/biometrics/#{run}"]))
    assert has_element?(view, "#subjects-subject_002")
    refute has_element?(view, "#subjects-subject_001")
    assert has_element?(view, "#tile-subject_002-mugshot_frontal img")
    assert has_element?(view, "#tile-subject_002-mugshot_left_profile img")
    refute has_element?(view, "#run-meta")
  end

  test "moves between shots and closes back to the identity", %{conn: conn, run: run} do
    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}/subject_001")

    view |> element("#tile-subject_001-mugshot_frontal a") |> render_click()
    assert_patch(view, ~p"/biometrics/#{run}/subject_001?#{[shot: "mugshot_frontal"]}")
    assert has_element?(view, "#shot-detail")

    view |> element("#next-shot") |> render_click()
    assert_patch(view, ~p"/biometrics/#{run}/subject_001?#{[shot: "mugshot_left_profile"]}")

    view |> element("#shot-detail") |> render_keydown(%{"key" => "Escape"})
    assert_patch(view, ~p"/biometrics/#{run}/subject_001")
    refute has_element?(view, "#shot-detail")
    assert has_element?(view, "#identity-header")
  end

  test "links each subject to its identity page", %{conn: conn, run: run} do
    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}")

    assert has_element?(view, ~s(#open-subject_001[href="/biometrics/#{run}/subject_001"]))
  end

  test "redirects to the run for unknown subjects", %{conn: conn, run: run} do
    assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/biometrics/#{run}/subject_999")
    assert to == ~p"/biometrics/#{run}"
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

  test "shows the quality report and each shot's verification", %{conn: conn, tmp_dir: root} do
    run = create_run(root, run: "verified-run", subjects: 1, shots: ["rolled"])

    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}")

    # 10 fingers: finger 5 accepted on a retry and finger 7 rejected (see stub_ridge/1).
    assert has_element?(view, "#report-verified", "10")
    assert has_element?(view, "#report-accepted", "8")
    assert has_element?(view, "#report-retried", "1")
    assert has_element?(view, "#report-rejected", "1")
    assert has_element?(view, "#report-impressions", "rolled")
    # One subject with one capture: no mated or non-mated pairs.
    assert has_element?(view, "#report-matching", "Needs rolled fingers")
    assert has_element?(view, "#tile-subject_001-rolled_07", "57")

    view |> element("#tile-subject_001-rolled_07 a") |> render_click()
    assert has_element?(view, "#verification-status", "Rejected")
    assert has_element?(view, "#verification", "97%")
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
