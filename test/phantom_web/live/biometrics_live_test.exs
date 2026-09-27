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
    assert has_element?(view, "#nav-biometrics[aria-current=page]")
    refute has_element?(view, "#nav-home[aria-current]")
    # Already on the page with the new-run form.
    refute has_element?(view, "#nav-new-run")
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

    assert has_element?(view, "#estimate-people", "2")
    assert has_element?(view, "#estimate-images", "4")
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

  test "fixes traits for everyone in the run and leaves the rest random", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/biometrics")

    assert has_element?(view, "#traits-summary", "Every trait is random")
    assert has_element?(view, "#batch_traits_0_sex_random[checked]")
    # Nobody has a distinguishing mark unless the run asks for one.
    assert has_element?(view, ~s(#batch_traits_0_mark option[value=""]), "None")
    assert has_element?(view, ~s(#batch_traits_0_mark option[value="random"]), "Random")
    # With sex random, clothes come grouped: for anyone, women's and men's.
    assert has_element?(view, ~s(#batch_traits_0_clothing optgroup[label="Women's"]))
    assert has_element?(view, ~s(#batch_traits_0_clothing optgroup[label="Men's"]))
    refute has_element?(view, "#batch_traits_0_facial_hair[disabled]")

    view
    |> form("#batch-form",
      batch: %{traits: %{sex: "female", ancestry: "Northern European", age_min: "30"}}
    )
    |> render_change()

    assert has_element?(view, "#traits-summary", "Female")
    assert has_element?(view, "#traits-summary", "Northern European")
    assert has_element?(view, "#traits-summary", "30–75 years")
    assert has_element?(view, "#traits-example", "-year-old woman with")
    assert has_element?(view, "#traits-example", "She is of Northern European descent")
    # Women have no facial hair; colours are the ones the ancestry has.
    assert has_element?(view, "#batch_traits_0_facial_hair[disabled]")
    assert has_element?(view, "#batch_traits_0_sex_female[checked]")
    # Only clothes for anyone and for women.
    refute has_element?(view, "#batch_traits_0_clothing optgroup")

    assert has_element?(
             view,
             ~s(#batch_traits_0_clothing option[value="a floral-print blouse with short sleeves and a round neck"])
           )

    assert has_element?(view, ~s(#batch_traits_0_clothing option[value="a plain black t-shirt"]))
    refute has_element?(view, ~s(#batch_traits_0_clothing option[value="a navy polo shirt"]))
    assert has_element?(view, ~s(#batch_traits_0_eye_color option[value="blue"]))
    refute has_element?(view, ~s(#batch_traits_0_eye_color option[value="dark brown"]))

    # A set trait goes back to random on its own.
    view |> element("#batch_traits_0_ancestry_clear") |> render_click()
    refute has_element?(view, "#traits-summary", "Northern European")
    assert has_element?(view, "#traits-summary", "Female")

    view
    |> form("#batch-form", batch: %{traits: %{age_min: "50", age_max: "40"}})
    |> render_change()

    assert has_element?(view, "#people-section", "must be at least the minimum age")
    assert has_element?(view, "#traits-example", "Fix the traits marked in red")

    view |> element("#random-traits") |> render_click()
    assert has_element?(view, "#traits-summary", "Every trait is random")

    assert {:error, {:live_redirect, %{to: "/biometrics/nordic"}}} =
             view
             |> form("#batch-form",
               batch: %{
                 subjects: "2",
                 run: "nordic",
                 shots: ["", "mugshot_frontal"],
                 traits: %{sex: "female", ancestry: "Northern European", eye_color: "blue"}
               }
             )
             |> render_submit()

    assert {:ok, run} = Biometrics.get_run("nordic")

    assert run.traits == %{
             "sex" => "female",
             "ancestry" => "Northern European",
             "eye_color" => "blue"
           }

    {:ok, view, _html} = live(conn, ~p"/biometrics")
    assert has_element?(view, "#run-traits-nordic", "Northern European")
  end

  test "ticks all, the default or none of a modality's shots", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/biometrics")
    assert has_element?(view, "#shot-mugshot_left_profile[checked]")
    refute has_element?(view, "#shot-probe_glasses[checked]")

    view |> element("#pick-face-all") |> render_click()
    assert has_element?(view, "#shot-probe_glasses[checked]")
    assert has_element?(view, "#group-rolled[checked]")

    view |> element("#pick-face-none") |> render_click()
    refute has_element?(view, "#shot-mugshot_left_profile[checked]")
    refute has_element?(view, "#needs-face")
    assert has_element?(view, "#needs-ridge")

    view |> element("#pick-ridge-none") |> render_click()
    assert has_element?(view, "#batch-form", "pick at least one shot")
    assert has_element?(view, "#start-run[disabled]")

    view |> element("#pick-face-default") |> render_click()
    assert has_element?(view, "#shot-probe_aged[checked]")
    refute has_element?(view, "#shot-probe_glasses[checked]")
    refute has_element?(view, "#group-rolled[checked]")

    # Faces need the biometrics service too, for the face gate.
    assert has_element?(view, "#needs-face")
    assert has_element?(view, "#needs-ridge", "face checks")
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
