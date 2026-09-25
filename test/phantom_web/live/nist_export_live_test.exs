defmodule PhantomWeb.NistExportLiveTest do
  use PhantomWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phantom.BiometricsFixtures

  alias Phantom.Biometrics
  alias Phantom.Biometrics.{Gallery, NistImages}

  setup do
    run =
      create_run(
        subjects: 1,
        shots: ["mugshot_left_profile", "probe_aged", "probe_appearance", "rolled_02", "palm_22"]
      )

    {:ok, subject} = Biometrics.get_subject(run, "subject_001")
    %{run: run, code: Gallery.code(subject.seed)}
  end

  test "shares the chosen export as a link", %{conn: conn, run: run, code: code} do
    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}/subject_001/nist")

    view |> form("#nist-form", nist: %{content: "prints"}) |> render_change()
    view |> element("#nist-share") |> render_click()

    assert has_element?(view, "#share-links", "#{code}_enrol.an2")
    assert has_element?(view, "#share-links", "Waiting to upload")
    assert_enqueued(worker: Phantom.Biometrics.Workers.UploadShare)

    {:ok, subject} = Biometrics.get_subject(run, "subject_001")
    assert [%{options: %{"content" => "prints"}}] = Biometrics.list_shares(subject)
  end

  test "shows what the enrolment holds and downloads it", %{conn: conn, run: run, code: code} do
    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}/subject_001/nist")

    assert has_element?(view, "h1", "NIST export")

    assert has_element?(
             view,
             ~s(label[for="nist_content_prints_faces"]),
             "2 faces, 1 rolled finger, 1 palm"
           )

    assert has_element?(view, "#nist_content_prints_faces[checked]")
    assert has_element?(view, "#nist_compression_png[checked]")

    assert has_element?(view, "#file-enrol", "#{code}_enrol.an2")

    assert has_element?(
             view,
             "#file-enrol",
             "2 × Type-10 face, 1 × Type-14 fingerprint, 1 × Type-15 palm"
           )

    assert has_element?(
             view,
             ~s(#nist-download[href="/biometrics/#{run}/subject_001/nist/download?compression=png&content=prints_faces"]),
             "Download .an2"
           )
  end

  test "picks the content, search probes and compression", %{conn: conn, run: run, code: code} do
    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}/subject_001/nist")

    assert has_element?(view, "#nist_search_probe_aged")
    assert has_element?(view, "#nist_search_probe_appearance")
    refute has_element?(view, "#nist_search_probe_glasses")

    view
    |> form("#nist-form",
      nist: %{content: "faces", search: ["", "probe_aged", "probe_appearance"]}
    )
    |> render_change()

    refute has_element?(view, "#file-enrol", "Type-14")
    assert has_element?(view, "#file-search_aged", "#{code}_search_aged.an2")
    assert has_element?(view, "#file-search_appearance", "Search: Appearance")
    assert has_element?(view, "#nist-download", "Download ZIP")

    assert view |> element("#nist-download") |> render() =~
             "compression=png&amp;content=faces&amp;search[]=probe_aged&amp;search[]=probe_appearance"

    if NistImages.wsq_available?() do
      view
      |> form("#nist-form", nist: %{content: "prints", compression: "wsq"})
      |> render_change()

      assert view |> element("#nist-download") |> render() =~ "compression=wsq"
      assert has_element?(view, "#file-enrol", "1 × Type-14 fingerprint, 1 × Type-15 palm")
      refute has_element?(view, "#file-enrol", "Type-10")
      # The search probes stay picked: they don't depend on what's enrolled.
      assert has_element?(view, "#file-search_aged")
    else
      assert has_element?(view, "#wsq-unavailable")
    end
  end

  test "says when there's nothing to export", %{conn: conn} do
    run = create_run(subjects: 1, shots: ["rolled_02"])
    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}/subject_001/nist")

    view |> form("#nist-form", nist: %{content: "faces"}) |> render_change()
    assert has_element?(view, "#nothing")
    refute has_element?(view, "#nist-download")
  end

  test "is linked from the subject's download menu", %{conn: conn, run: run} do
    {:ok, view, _html} = live(conn, ~p"/biometrics/#{run}/subject_001")

    assert has_element?(view, ~s(#download-nist[href="/biometrics/#{run}/subject_001/nist"]))
  end

  test "goes back to the run for an unknown subject", %{conn: conn, run: run} do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, ~p"/biometrics/#{run}/subject_999/nist")

    assert to == ~p"/biometrics/#{run}"
  end
end
