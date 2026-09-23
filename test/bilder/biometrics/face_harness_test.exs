defmodule Bilder.Biometrics.FaceHarnessTest do
  use ExUnit.Case, async: true

  alias Bilder.Biometrics.FaceHarness

  @moduletag :tmp_dir

  @anchor_png <<137, 80, 78, 71, 13, 10, 26, 10>> <> "anchor"
  @other_png <<137, 80, 78, 71, 13, 10, 26, 10>> <> "other"

  # Replies with @anchor_png for text-only requests and @other_png for
  # image-conditioned ones, and reports each request to the test process.
  defp stub_service(test_pid) do
    Req.Test.stub(Bilder.ImageGeneration, fn conn ->
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

  test "renders the anchor from text and conditions other shots on it", %{tmp_dir: tmp_dir} do
    stub_service(self())

    assert {:ok, result} =
             FaceHarness.run(
               out: tmp_dir,
               run: "r1",
               seed: 42,
               subjects: 2,
               steps: 20,
               shots: ["mugshot_left_profile", "icao_portrait"]
             )

    assert [%{id: "subject_001"}, %{id: "subject_002"}] = result.subjects

    # Anchor first, then the conditioned shots, for each subject.
    for _subject <- 1..2 do
      assert_received {:render, %{"width" => "896", "height" => "1120", "steps" => "20"}, []}
      assert_received {:render, %{"prompt" => profile}, [@anchor_png]}
      assert profile =~ "left profile"
      assert_received {:render, %{"height" => "1152"}, [@anchor_png]}
    end

    dir = Path.join([tmp_dir, "r1", "subject_001"])
    assert File.read!(Path.join(dir, "mugshot_frontal.png")) == @anchor_png
    assert File.read!(Path.join(dir, "mugshot_left_profile.png")) == @other_png

    subject = dir |> Path.join("subject.json") |> File.read!() |> Jason.decode!()
    assert Enum.map(subject["shots"], & &1["pos"]) == ["F", "L", "F"]
    assert Enum.all?(subject["shots"], &(&1["status"] == "ok"))

    assert File.read!(result.index) =~ "subject_002/icao_portrait.png"
    assert %{"seed" => 42} = Jason.decode!(File.read!(Path.join([tmp_dir, "r1", "run.json"])))
  end

  test "resuming a run skips existing images and uses the same seeds", %{tmp_dir: tmp_dir} do
    stub_service(self())
    opts = [out: tmp_dir, run: "r2", seed: 7, subjects: 1, shots: ["probe_aged"]]

    assert {:ok, first} = FaceHarness.run(opts)
    assert_received {:render, %{"seed" => anchor_seed}, []}
    assert_received {:render, _params, [_anchor]}

    File.rm!(Path.join([tmp_dir, "r2", "subject_001", "probe_aged.png"]))
    assert {:ok, second} = FaceHarness.run(opts)

    refute_received {:render, _params, []}
    assert_received {:render, _params, [@anchor_png]}

    [%{shots: [anchor, _probe]}] = second.subjects
    assert anchor.status == "existing"
    assert Integer.to_string(anchor.seed) == anchor_seed

    assert Enum.map(first.subjects, & &1.description) ==
             Enum.map(second.subjects, & &1.description)
  end

  test "skips conditioned shots when the anchor fails", %{tmp_dir: tmp_dir} do
    Req.Test.stub(Bilder.ImageGeneration, fn conn ->
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    assert {:ok, %{subjects: [%{shots: [anchor, profile]}]}} =
             FaceHarness.run(
               out: tmp_dir,
               run: "r3",
               subjects: 1,
               shots: ["mugshot_left_profile"]
             )

    assert anchor.status == "error"
    assert profile.status == "skipped"
    assert File.read!(Path.join([tmp_dir, "r3", "index.html"])) =~ "anchor shot failed"
  end

  test "rejects unknown shots" do
    assert {:error, message} = FaceHarness.run(shots: ["selfie"])
    assert message =~ "selfie"
  end
end
