defmodule PhantomWeb.BiometricsLiveTest do
  # Renders runs in a separate process in some tests: shared sandbox and stubs.
  use PhantomWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Phantom.BiometricsFixtures

  alias Phantom.Biometrics

  setup {Req.Test, :set_req_test_to_shared}

  setup do
    stub_qwen()
    stub_ridge()
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

  test "lists existing runs", %{conn: conn} do
    run = create_run()
    {:ok, view, _html} = live(conn, ~p"/biometrics")

    assert has_element?(view, ~s(#runs-#{run}[href="/biometrics/#{run}"]))
    refute has_element?(view, "#runs-empty")
  end

  test "validates the form and updates the estimate", %{conn: conn} do
    run = create_run()
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

  test "queues a run and navigates to it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/biometrics")

    assert {:error, {:live_redirect, %{to: "/biometrics/ui-run"}}} =
             view
             |> form("#batch-form",
               batch: %{subjects: "1", run: "ui-run", shots: ["", "rolled"]}
             )
             |> render_submit()

    render_queued()
    assert {:ok, %{images: images}} = Biometrics.get_subject("ui-run", "subject_001")
    assert Enum.any?(images, &(&1.shot == "rolled_10" and &1.status == :ok))
    refute Enum.any?(images, &(&1.shot == "mugshot_frontal"))
  end

  test "shows the active run while it renders and cancels it", %{conn: conn} do
    test_pid = self()

    stub_qwen(
      generate: fn conn ->
        send(test_pid, :rendering)

        receive do
          :continue -> send_png(conn)
        end
      end
    )

    {:ok, view, _html} = live(conn, ~p"/biometrics")

    {:ok, _run} =
      Biometrics.create_run(%{run: "busy-run", subjects: 1, shots: ["mugshot_frontal"]})

    {:ok, next} =
      Biometrics.create_run(%{run: "next-run", subjects: 1, shots: ["mugshot_frontal"]})

    assert has_element?(view, "#run-status-next-run", "queued")

    rendering = render_queued_async()
    assert_receive :rendering

    assert has_element?(view, "#active-run", "busy-run")
    assert has_element?(view, "#run-status-busy-run", "running")
    # Another run can still be queued behind it.
    refute has_element?(view, "#start-run[disabled]")

    view |> element("#cancel-run") |> render_click()
    refute has_element?(view, "#active-run")
    assert has_element?(view, "#run-status-busy-run", "cancelled")

    # Let the render that was in flight finish, without starting the next run.
    Biometrics.cancel_run(next)
    send(rendering.pid, :continue)
    Task.await(rendering)
  end
end
