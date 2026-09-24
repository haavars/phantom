defmodule Phantom.Biometrics.RunsTest do
  use Phantom.DataCase, async: true

  import Phantom.BiometricsFixtures

  alias Phantom.Biometrics.Runs

  test "lists runs with their progress and a cover image" do
    run = create_run()

    assert [%{name: ^run, seed: 42, subject_count: 2, completed_subjects: 2} = listed] =
             Enum.filter(Runs.list_runs(), &(&1.name == run))

    assert listed.shots == ["mugshot_frontal", "mugshot_left_profile"]
    assert listed.status == "finished"
    assert %{shot: "mugshot_frontal"} = listed.cover
    assert {:ok, %{name: ^run, completed_subjects: 2}} = Runs.summary(run)
  end

  test "reads a run with its subjects and images in order" do
    run = create_run()

    assert {:ok, %{subjects: [first, _second]}} = Runs.get_run(run)
    assert %{name: "subject_001", description: description, images: [anchor, profile]} = first
    assert description =~ "year-old"
    assert %{shot: "mugshot_frontal", pos: "F", status: "ok", reference_id: nil} = anchor
    assert %{shot: "mugshot_left_profile", pos: "L"} = profile
    assert profile.reference_id == anchor.id

    assert {:ok, %{id: id, images: [_, _]}} = Runs.get_subject(run, "subject_001")
    assert id == first.id
    assert {:ok, %{shot: "mugshot_frontal"}} = Runs.get_image(anchor.id)
  end

  test "returns not_found for missing runs, subjects and images" do
    run = create_run()

    assert {:error, :not_found} = Runs.get_run("missing")
    assert {:error, :not_found} = Runs.summary("missing")
    assert {:error, :not_found} = Runs.get_subject(run, "subject_999")
    assert {:error, :not_found} = Runs.get_image(-1)
    refute Runs.exists?("missing")
    assert Runs.exists?(run)
  end

  test "starting a run with an existing name restarts it" do
    run = create_run()
    {:ok, before} = Runs.get_run(run)

    assert {:ok, restarted} =
             Runs.start_run(%{name: run, seed: 42, subject_count: 3, shots: before.shots})

    assert restarted.id == before.id
    assert %{status: "running", subject_count: 3, finished_at: nil} = restarted
  end

  test "marks interrupted runs as cancelled" do
    {:ok, run} = Runs.start_run(%{name: unique_run_name(), seed: 1, subject_count: 1})

    assert Runs.interrupt_running() >= 1
    assert {:ok, %{status: "cancelled", finished_at: %DateTime{}}} = Runs.summary(run.name)
  end

  test "records why a run failed" do
    {:ok, run} = Runs.start_run(%{name: unique_run_name(), seed: 1, subject_count: 1})

    assert {:ok, %{status: "failed", error: "boom"}} =
             Runs.finish_run_by_name(run.name, "failed", "boom")
  end
end
