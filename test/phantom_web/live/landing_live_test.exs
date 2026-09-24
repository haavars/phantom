defmodule PhantomWeb.LandingLiveTest do
  use PhantomWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Phantom.BiometricsFixtures

  setup {Req.Test, :set_req_test_to_shared}

  test "explains the project and shows an empty gallery", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#hero")
    assert has_element?(view, ~s(#cta-start[href="/biometrics"]))
    assert has_element?(view, "#how-it-works")
    assert has_element?(view, "#modalities")
    refute has_element?(view, "#identities article")
    assert has_element?(view, "#nav-home[aria-current=page]")
    assert has_element?(view, ~s(#brand img[src="/images/icon.svg"]))
    assert has_element?(view, "#nav-new-run")
    assert has_element?(view, "#site-footer", "None of these people exist")
  end

  test "lists identities that link to their subject", %{conn: conn} do
    faces = create_run(subjects: 1)
    ridges = create_run(subjects: 1, shots: ["rolled"])

    {:ok, view, _html} = live(conn, ~p"/")

    face = "#identities-#{faces}--subject_001"
    ridge = "#identities-#{ridges}--subject_001"

    assert has_element?(
             view,
             ~s(#{face} a[href="/biometrics/#{faces}/subject_001"])
           )

    assert has_element?(
             view,
             ~s(#{face} img[src^="/images/"])
           )

    assert has_element?(
             view,
             ~s(#{ridge} a[href="/biometrics/#{ridges}/subject_001"])
           )

    assert has_element?(
             view,
             ~s(#{ridge} img[src^="/images/"])
           )
  end

  test "filters by modality", %{conn: conn} do
    faces = create_run(subjects: 1)
    ridges = create_run(subjects: 1, shots: ["rolled"])

    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#filter-prints") |> render_click()
    assert has_element?(view, "#identities-#{ridges}--subject_001")
    refute has_element?(view, "#identities-#{faces}--subject_001")
    assert has_element?(view, ~s(#filter-prints[aria-selected="true"]))

    view |> element("#filter-faces") |> render_click()
    assert has_element?(view, "#identities-#{faces}--subject_001")
    refute has_element?(view, "#identities-#{ridges}--subject_001")

    view |> element("#filter-all") |> render_click()
    assert has_element?(view, "#identities-#{faces}--subject_001")
    assert has_element?(view, "#identities-#{ridges}--subject_001")
  end
end
