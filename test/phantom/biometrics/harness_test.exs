defmodule Phantom.Biometrics.HarnessTest do
  use Phantom.DataCase, async: true

  import Phantom.BiometricsFixtures, only: [stub_ridge: 0, stub_ridge: 1, unique_run_name: 1]

  alias Phantom.Biometrics.{Harness, Runs, Storage}

  @anchor_png <<137, 80, 78, 71, 13, 10, 26, 10>> <> "anchor"
  @other_png <<137, 80, 78, 71, 13, 10, 26, 10>> <> "other"

  # Replies with @anchor_png for text-only requests and @other_png for
  # image-conditioned ones, and reports each request to the test process.
  defp stub_service(test_pid) do
    Req.Test.stub(Phantom.ImageGeneration, fn conn ->
      conn =
        Plug.Parsers.call(
          conn,
          Plug.Parsers.init(parsers: [Plug.Parsers.MULTIPART], length: 20_000_000)
        )

      references = conn.params |> Map.get("images") |> List.wrap()
      send(test_pid, {:render, conn.params, Enum.map(references, &File.read!(&1.path))})

      conn
      |> Plug.Conn.put_resp_header("x-seed", conn.params["seed"])
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, if(references == [], do: @anchor_png, else: @other_png))
    end)
  end

  defp image(run, subject, shot) do
    {:ok, subject} = Runs.get_subject(run, subject)
    Enum.find(subject.images, &(&1.shot == shot))
  end

  test "renders the anchor from text and conditions other shots on it" do
    stub_service(self())
    name = unique_run_name("faces")

    assert {:ok, result} =
             Harness.run(
               run: name,
               seed: 42,
               subjects: 2,
               steps: 20,
               shots: ["mugshot_left_profile", "icao_portrait"]
             )

    assert [%{name: "subject_001"}, %{name: "subject_002"}] = result.subjects
    assert %{name: ^name, seed: 42, status: "finished", subject_count: 2} = result.run

    # Anchor first, then the conditioned shots, for each subject.
    for _subject <- 1..2 do
      assert_received {:render, %{"width" => "896", "height" => "1120", "steps" => "20"}, []}
      assert_received {:render, %{"prompt" => profile}, [@anchor_png]}
      assert profile =~ "left profile"
      assert_received {:render, %{"height" => "1152"}, [@anchor_png]}
    end

    anchor = image(name, "subject_001", "mugshot_frontal")
    profile = image(name, "subject_001", "mugshot_left_profile")

    assert anchor.storage_key == "#{name}/subject_001/mugshot_frontal.png"
    assert Storage.read(anchor.storage_key) == {:ok, @anchor_png}
    assert Storage.read(profile.storage_key) == {:ok, @other_png}
    assert anchor.byte_size == byte_size(@anchor_png)
    assert anchor.sha256 == :crypto.hash(:sha256, @anchor_png) |> Base.encode16(case: :lower)
    assert profile.reference_id == anchor.id
    assert profile.prompt =~ "left profile"

    {:ok, subject} = Runs.get_subject(name, "subject_001")
    assert Enum.map(subject.images, & &1.pos) == ["F", "L", "F"]
    assert Enum.all?(subject.images, &(&1.status == "ok"))
    assert subject.completed_at
    assert %{"sex" => _, "age" => _} = subject.attributes
  end

  test "resuming a run keeps stored images and uses the same seeds" do
    stub_service(self())
    opts = [run: unique_run_name("resume"), seed: 7, subjects: 1, shots: ["probe_aged"]]

    assert {:ok, first} = Harness.run(opts)
    assert_received {:render, %{"seed" => anchor_seed}, []}
    assert_received {:render, _params, [_anchor]}

    probe = image(opts[:run], "subject_001", "probe_aged")
    File.rm!(Path.join(Storage.Local.root(), probe.storage_key))
    assert {:ok, second} = Harness.run(opts)

    refute_received {:render, _params, []}
    assert_received {:render, _params, [@anchor_png]}

    [%{images: [anchor, _probe]}] = second.subjects
    assert anchor.id == hd(hd(first.subjects).images).id
    assert Integer.to_string(anchor.seed) == anchor_seed

    assert Enum.map(first.subjects, & &1.description) ==
             Enum.map(second.subjects, & &1.description)
  end

  test "skips conditioned shots when the anchor fails" do
    Req.Test.stub(Phantom.ImageGeneration, fn conn ->
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    assert {:ok, %{subjects: [%{images: [anchor, profile]}]}} =
             Harness.run(
               run: unique_run_name("broken"),
               subjects: 1,
               shots: ["mugshot_left_profile"]
             )

    assert %{status: "error", storage_key: nil} = anchor
    assert %{status: "skipped", error: "anchor shot failed"} = profile
  end

  test "rejects unknown shots" do
    assert {:error, message} = Harness.run(shots: ["selfie"])
    assert message =~ "selfie"
  end

  test "renders friction-ridge shots from the subject seed, with ground truth and no face anchor" do
    stub_ridge(notify: self())
    name = unique_run_name("ridge")

    assert {:ok, %{subjects: [subject]}} =
             Harness.run(run: name, seed: 5, subjects: 1, shots: ["slaps"], captures: 2)

    renders =
      for _ <- 1..6 do
        assert_received {:ridge_render, body}
        body
      end

    assert Enum.map(renders, &{&1["kind"], &1["code"], &1["capture"]}) == [
             {"slap", 13, 0},
             {"slap", 14, 0},
             {"slap", 15, 0},
             {"slap", 13, 1},
             {"slap", 14, 1},
             {"slap", 15, 1}
           ]

    # Every image of the subject comes from the same seed: same fingers.
    assert renders |> Enum.map(& &1["seed"]) |> Enum.uniq() == [subject.seed]
    # Diffusion is the default renderer.
    assert renders |> Enum.map(& &1["renderer"]) |> Enum.uniq() == ["diffusion"]

    refute Enum.any?(subject.images, &(&1.shot == "mugshot_frontal"))
    assert Storage.exists?("#{name}/subject_001/slap_15_c2.png")

    slap = image(name, "subject_001", "slap_13")
    assert %{shot: "slap_13", modality: "ridge", pos: "13", status: "ok", capture: 0} = slap
    assert length(slap.ground_truth["minutiae"]) == 2
    assert slap.ground_truth["generator"] == "ridgegen/test"
    assert slap.meta["minutiae_count"] == 2
    refute Map.has_key?(slap.meta, "minutiae")
    assert image(name, "subject_001", "slap_13_c2").capture == 1
  end

  test "passes the renderer to the service and records it" do
    stub_ridge(notify: self())

    assert {:ok, %{run: run}} =
             Harness.run(
               run: unique_run_name("draft"),
               seed: 5,
               subjects: 1,
               shots: ["rolled_04"],
               renderer: "procedural"
             )

    assert_received {:ridge_render, %{"renderer" => "procedural"}}
    assert run.renderer == "procedural"
  end

  test "resuming keeps the ground truth of stored friction-ridge shots" do
    stub_ridge(notify: self())
    opts = [run: unique_run_name("ridge-resume"), seed: 5, subjects: 1, shots: ["rolled_04"]]

    assert {:ok, _result} = Harness.run(opts)
    assert_received {:ridge_render, _body}

    assert {:ok, %{subjects: [%{images: [image]}]}} = Harness.run(opts)
    refute_received {:ridge_render, _body}

    assert %{status: "ok", meta: %{"pattern" => "whorl"}, ground_truth: %{"minutiae" => [_, _]}} =
             image
  end

  test "stores a quality report for verified friction-ridge shots" do
    stub_ridge()

    assert {:ok, %{run: run, report: report}} =
             Harness.run(
               run: unique_run_name("report"),
               seed: 5,
               subjects: 2,
               shots: ["rolled_02", "rolled_05", "rolled_07"],
               captures: 2
             )

    # Finger 5 is accepted on a retry and finger 7 rejected (see stub_ridge/1).
    assert %{"verified" => 12, "accepted" => 4, "retried" => 4, "rejected" => 4} =
             report["verification"]

    assert %{"count" => 12, "min" => 52, "max" => 57} =
             report["verification"]["by_impression"]["rolled"]["nfiq2"]

    # Mated: each finger's two captures, per subject. Non-mated: each finger across subjects.
    assert %{
             "mated" => %{"count" => 6, "min" => 250},
             "non_mated" => %{"count" => 3, "max" => 10},
             "false_non_matches" => 0,
             "false_matches" => 0
           } = report["matching"]

    assert {:ok, %{report: ^report}} = Runs.get_run(run.name)

    # `meta` keeps the scores; the minutiae lists stay in the ground truth.
    finger = image(run.name, "subject_001", "rolled_02")
    assert %{"nfiq2" => 52, "accepted" => true} = check = finger.meta["verification"]
    refute Map.has_key?(check, "detected")
    assert length(finger.ground_truth["verification"]["detected"]) == 2
  end

  test "runs without verified images get no report" do
    stub_service(self())

    assert {:ok, %{run: run, report: nil}} =
             Harness.run(
               run: unique_run_name("no-report"),
               seed: 5,
               subjects: 1,
               shots: ["mugshot_left_profile"]
             )

    assert run.report == nil
  end
end
