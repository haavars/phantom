defmodule PhantomWeb.BiometricsRunLiveTest do
  # Renders runs in a separate process in some tests: shared sandbox and stubs.
  use PhantomWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Phantom.BiometricsFixtures

  alias Phantom.Biometrics

  setup {Req.Test, :set_req_test_to_shared}

  setup do
    {:ok, run: create_run()}
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

  test "offers the identity as a download: everything, faces or prints", %{conn: conn} do
    run = create_run(subjects: 1, shots: ["mugshot_left_profile", "rolled_02"])

    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}/subject_001")

    assert has_element?(view, "#download-toggle")

    assert has_element?(
             view,
             ~s(#download-all[href="/biometrics/#{run}/subject_001/download?include=all"]),
             "3 images"
           )

    assert has_element?(view, ~s(#download-faces[href$="include=faces"]), "2 images")
    assert has_element?(view, ~s(#download-prints[href$="include=prints"]), "1 image")
    refute has_element?(view, "#download-menu", "Still rendering")

    # On the run page, each subject has a download link too.
    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}")

    assert has_element?(
             view,
             ~s(#download-subject_001[href="/biometrics/#{run}/subject_001/download"])
           )
  end

  test "only offers the downloads that have images", %{conn: conn} do
    run = create_run(subjects: 1, shots: ["rolled_02"])

    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}/subject_001")
    assert has_element?(view, "#download-all")
    assert has_element?(view, "#download-prints")
    refute has_element?(view, "#download-faces")
  end

  test "shares a download as a link and shows it once uploaded", %{conn: conn, run: run} do
    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}/subject_001")
    refute has_element?(view, "#share-links")

    view |> element("#share-faces") |> render_click()
    assert has_element?(view, "#share-links", "Waiting to upload")

    Req.Test.stub(Phantom.S3, &Plug.Conn.send_resp(&1, 200, ""))
    Oban.drain_queue(queue: :transfers, with_safety: false)

    assert has_element?(view, "#share-links input[value*='X-Amz-Signature=']")
    assert has_element?(view, "#share-links", "Link works until")
    assert has_element?(view, "#share-links button", "New link")
  end

  test "downloads the shot in the detail view", %{conn: conn, run: run} do
    {:ok, view, _html} =
      live(conn, ~p"/biometrics/#{run}?#{[subject: "subject_001", shot: "mugshot_frontal"]}")

    assert has_element?(view, ~s(#download-shot[href$="?download=1"]))
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

  test "resumes an incomplete run and shows new subjects live", %{conn: conn, run: run} do
    # Pretend the run was meant to have a third subject.
    {:ok, stored} = Biometrics.get_run(run)
    stored |> Ecto.Changeset.change(subject_count: 3) |> Phantom.Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}")
    refute has_element?(view, "#subjects-subject_003")

    view |> element("#resume-run") |> render_click()
    assert has_element?(view, "#run-status", "queued")
    assert has_element?(view, "#cancel-run")

    render_queued()

    assert has_element?(view, "#tile-subject_003-mugshot_left_profile img")
    refute has_element?(view, "#resume-run")
    refute has_element?(view, "#run-status")
  end

  test "offers to resume a finished run with deleted images", %{conn: conn, run: run} do
    {:ok, %{subjects: [subject | _]}} = Biometrics.get_run(run)
    [image | _] = subject.images
    File.rm!(Path.join(Phantom.Biometrics.Storage.Local.root(), image.storage_key))

    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}")
    assert has_element?(view, "#missing-images", "1 subject is missing images")

    view |> element("#resume-run") |> render_click()
    assert has_element?(view, "#run-status", "queued")
    refute has_element?(view, "#missing-images")

    render_queued()
    refute has_element?(view, "#resume-run")
    assert Phantom.Biometrics.Storage.exists?(image.storage_key)
  end

  test "adds shots to a finished run", %{conn: conn, run: run} do
    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}")
    refute has_element?(view, "#add-shots-form")

    view |> element("#add-shots") |> render_click()
    # Shots the run has aren't offered again.
    refute has_element?(view, "#add-mugshot_left_profile")
    assert has_element?(view, "#add-probe_glasses")
    assert has_element?(view, "#add-slaps")

    view |> form("#add-shots-form") |> render_submit(%{add: %{shots: [""]}})
    assert has_element?(view, "#add-shots-error", "Pick at least one shot.")

    view |> form("#add-shots-form") |> render_submit(%{add: %{shots: ["", "probe_glasses"]}})
    refute has_element?(view, "#add-shots-form")
    refute has_element?(view, "#add-shots")
    assert has_element?(view, "#run-status", "queued")
    assert has_element?(view, "#tile-subject_001-probe_glasses")

    render_queued()
    assert has_element?(view, "#tile-subject_001-probe_glasses img")
    assert has_element?(view, "#tile-subject_002-probe_glasses img")
    assert has_element?(view, "#add-shots")
  end

  test "shows the traits every subject shares", %{conn: conn} do
    run = create_run(subjects: 1, traits: %{ancestry: "South Asian", build: "slim"})

    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}")
    assert has_element?(view, "#run-traits", "South Asian · slim build")
  end

  test "redirects to the run list for unknown runs", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/biometrics"}}} = live(conn, ~p"/biometrics/missing")
  end

  test "groups friction-ridge shots and shows their ground truth", %{conn: conn} do
    run = create_run(subjects: 1, shots: ["mugshot_left_profile", "rolled"])

    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}")

    assert has_element?(view, "#subject_001-face-0")
    assert has_element?(view, "#subject_001-rolled-0", "Rolled fingers")
    assert has_element?(view, "#tile-subject_001-rolled_03 img")
    assert has_element?(view, "#tile-subject_001-rolled_03", "W")

    view |> element("#tile-subject_001-rolled_03 a") |> render_click()
    assert has_element?(view, "#ridge-meta", "whorl")
    assert has_element?(view, "#ridge-meta", "2 cores, 2 deltas")
    assert has_element?(view, ~s(#ground-truth-link[href$="/ground-truth"]))
    refute has_element?(view, "#shot-prompt")
  end

  test "shows the quality report and each shot's verification", %{conn: conn} do
    run = create_run(subjects: 1, shots: ["rolled"])

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

  test "opens a face shot of the subject that is still rendering", %{conn: conn} do
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

    {:ok, _run} =
      Biometrics.create_run(%{run: "live-run", subjects: 1, shots: ["mugshot_left_profile"]})

    rendering = render_queued_async()
    assert_receive :rendering

    {:ok, view, _html} =
      live(conn, ~p"/biometrics/live-run?#{[subject: "subject_001", shot: "mugshot_frontal"]}")

    assert has_element?(view, "#shot-detail")
    assert has_element?(view, "#shot-prompt", "Police booking photograph")
    refute has_element?(view, "#ridge-meta")
    assert has_element?(view, "#run-progress")

    send(rendering.pid, :continue)
    Task.await(rendering)
  end
end
