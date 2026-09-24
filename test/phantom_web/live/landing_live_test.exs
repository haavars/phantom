defmodule PhantomWeb.LandingLiveTest do
  # Uses the global biometrics output dir.
  use PhantomWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Phantom.BiometricsFixtures

  @moduletag :tmp_dir

  setup {Req.Test, :set_req_test_to_shared}

  setup %{tmp_dir: root} do
    use_output_dir(root)
    :ok
  end

  test "explains the project and shows an empty gallery", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#hero")
    assert has_element?(view, ~s(#cta-start[href="/biometrics"]))
    assert has_element?(view, "#how-it-works")
    assert has_element?(view, "#modalities")
    refute has_element?(view, "#identities article")
    assert has_element?(view, "#nav-home")
  end

  test "lists identities that link to their subject", %{conn: conn, tmp_dir: root} do
    create_run(root, run: "faces", subjects: 1)
    create_run(root, run: "ridges", subjects: 1, shots: ["rolled"])

    {:ok, view, _html} = live(conn, ~p"/")

    face = "#identities-faces--subject_001"
    ridge = "#identities-ridges--subject_001"

    assert has_element?(
             view,
             ~s(#{face} a[href="/biometrics/faces?shot=mugshot_frontal&subject=subject_001"])
           )

    assert has_element?(
             view,
             ~s(#{face} img[src="/biometrics-files/faces/subject_001/mugshot_frontal.png"])
           )

    assert has_element?(
             view,
             ~s(#{ridge} a[href="/biometrics/ridges?shot=rolled_02&subject=subject_001"])
           )

    assert has_element?(
             view,
             ~s(#{ridge} img[src="/biometrics-files/ridges/subject_001/rolled_02.png"])
           )
  end

  test "filters by modality", %{conn: conn, tmp_dir: root} do
    create_run(root, run: "faces", subjects: 1)
    create_run(root, run: "ridges", subjects: 1, shots: ["rolled"])

    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#filter-prints") |> render_click()
    assert has_element?(view, "#identities-ridges--subject_001")
    refute has_element?(view, "#identities-faces--subject_001")
    assert has_element?(view, ~s(#filter-prints[aria-selected="true"]))

    view |> element("#filter-faces") |> render_click()
    assert has_element?(view, "#identities-faces--subject_001")
    refute has_element?(view, "#identities-ridges--subject_001")

    view |> element("#filter-all") |> render_click()
    assert has_element?(view, "#identities-faces--subject_001")
    assert has_element?(view, "#identities-ridges--subject_001")
  end
end
