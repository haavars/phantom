defmodule Bilder.Biometrics.FaceRunsTest do
  use ExUnit.Case, async: true

  import Bilder.FaceFixtures

  alias Bilder.Biometrics.FaceRuns

  @moduletag :tmp_dir

  test "lists and reads runs from the output folder", %{tmp_dir: root} do
    run = create_face_run(root)
    File.mkdir_p!(Path.join(root, "not-a-run"))

    assert [%{name: ^run, seed: 42, subjects: 2, completed: 2} = summary] =
             FaceRuns.list_runs(root)

    assert summary.shots == ["mugshot_frontal", "mugshot_left_profile"]
    assert summary.cover == {"subject_001", "mugshot_frontal.png"}

    assert {:ok, %{subjects_list: [first, _second]}} = FaceRuns.get_run(run, root)
    assert %{id: "subject_001", description: description, shots: [anchor, profile]} = first
    assert description =~ "year-old"
    assert %{shot: "mugshot_frontal", pos: "F", status: "ok", reference: nil} = anchor
    assert %{shot: "mugshot_left_profile", pos: "L", reference: "mugshot_frontal.png"} = profile

    assert {:ok, ^first} = FaceRuns.get_subject(run, "subject_001", root)
  end

  test "returns not_found for missing runs and unsafe names", %{tmp_dir: root} do
    run = create_face_run(root)

    assert {:error, :not_found} = FaceRuns.get_run("missing", root)
    assert {:error, :not_found} = FaceRuns.get_run("..", root)
    assert {:error, :not_found} = FaceRuns.get_subject(run, "../#{run}", root)
    assert FaceRuns.list_runs(Path.join(root, "nope")) == []
  end

  test "file_path/4 only resolves existing png and json files inside a run", %{tmp_dir: root} do
    run = create_face_run(root)

    assert {:ok, path} = FaceRuns.file_path(run, "subject_001", "mugshot_frontal.png", root)
    assert File.read!(path) == png()
    assert {:ok, _path} = FaceRuns.file_path(run, "subject_001", "subject.json", root)

    assert {:error, :not_found} = FaceRuns.file_path(run, "subject_001", "missing.png", root)
    assert {:error, :not_found} = FaceRuns.file_path(run, "..", "run.json", root)
    assert {:error, :not_found} = FaceRuns.file_path("..", run, "run.json", root)
    assert {:error, :not_found} = FaceRuns.file_path(run, "subject_001", "..", root)
  end
end
