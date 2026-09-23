defmodule Bilder.Biometrics.RunsTest do
  use ExUnit.Case, async: true

  import Bilder.BiometricsFixtures

  alias Bilder.Biometrics.Runs

  @moduletag :tmp_dir

  test "lists and reads runs from the output folder", %{tmp_dir: root} do
    run = create_run(root)
    File.mkdir_p!(Path.join(root, "not-a-run"))

    assert [%{name: ^run, seed: 42, subjects: 2, completed: 2} = summary] =
             Runs.list_runs(root)

    assert summary.shots == ["mugshot_frontal", "mugshot_left_profile"]
    assert summary.cover == {"subject_001", "mugshot_frontal.png"}

    assert {:ok, %{subjects_list: [first, _second]}} = Runs.get_run(run, root)
    assert %{id: "subject_001", description: description, shots: [anchor, profile]} = first
    assert description =~ "year-old"
    assert %{shot: "mugshot_frontal", pos: "F", status: "ok", reference: nil} = anchor
    assert %{shot: "mugshot_left_profile", pos: "L", reference: "mugshot_frontal.png"} = profile

    assert {:ok, ^first} = Runs.get_subject(run, "subject_001", root)
  end

  test "returns not_found for missing runs and unsafe names", %{tmp_dir: root} do
    run = create_run(root)

    assert {:error, :not_found} = Runs.get_run("missing", root)
    assert {:error, :not_found} = Runs.get_run("..", root)
    assert {:error, :not_found} = Runs.get_subject(run, "../#{run}", root)
    assert Runs.list_runs(Path.join(root, "nope")) == []
  end

  test "file_path/4 only resolves existing png and json files inside a run", %{tmp_dir: root} do
    run = create_run(root)

    assert {:ok, path} = Runs.file_path(run, "subject_001", "mugshot_frontal.png", root)
    assert File.read!(path) == png()
    assert {:ok, _path} = Runs.file_path(run, "subject_001", "subject.json", root)

    assert {:error, :not_found} = Runs.file_path(run, "subject_001", "missing.png", root)
    assert {:error, :not_found} = Runs.file_path(run, "..", "run.json", root)
    assert {:error, :not_found} = Runs.file_path("..", run, "run.json", root)
    assert {:error, :not_found} = Runs.file_path(run, "subject_001", "..", root)
  end
end
