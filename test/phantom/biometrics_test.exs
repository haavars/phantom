defmodule Phantom.BiometricsTest do
  use Phantom.DataCase, async: true

  import Phantom.BiometricsFixtures

  alias Phantom.Biometrics
  alias Phantom.Biometrics.Workers.GenerateSubject

  describe "reading runs" do
    test "lists runs with their progress and a cover image" do
      run = create_run()

      assert [%{name: ^run, seed: 42, subject_count: 2, completed_subjects: 2} = listed] =
               Biometrics.list_runs()

      assert listed.shots == ["mugshot_frontal", "mugshot_left_profile"]
      assert listed.status == :finished
      assert %{shot: "mugshot_frontal"} = listed.cover
    end

    test "reads a run with its subjects and images in order" do
      run = create_run()

      assert {:ok, %{subjects: [first, _second], completed_subjects: 2}} = Biometrics.get_run(run)
      assert %{name: "subject_001", description: description, images: [anchor, profile]} = first
      assert description =~ "year-old"
      assert %{shot: "mugshot_frontal", pos: "F", status: :ok, reference_id: nil} = anchor
      assert %{shot: "mugshot_left_profile", pos: "L"} = profile
      assert profile.reference_id == anchor.id

      assert {:ok, %{id: id, images: [_, _]}} = Biometrics.get_subject(run, "subject_001")
      assert id == first.id
      assert {:ok, %{shot: "mugshot_frontal"}} = Biometrics.get_image(anchor.id)
      assert {:ok, path} = Biometrics.image_path(anchor)
      assert File.read!(path) == png()
    end

    test "returns not_found for missing runs, subjects and images" do
      run = create_run()

      assert {:error, :not_found} = Biometrics.get_run("missing")
      assert {:error, :not_found} = Biometrics.get_subject(run, "subject_999")
      assert {:error, :not_found} = Biometrics.get_image(-1)
      refute Biometrics.run_exists?("missing")
      assert Biometrics.run_exists?(run)
    end
  end

  describe "create_run/1" do
    test "queues the run with one job per subject" do
      Biometrics.subscribe()

      assert {:ok, run} =
               Biometrics.create_run(%{
                 subjects: 3,
                 seed: 9,
                 shots: ["rolled", "card"],
                 captures: 2
               })

      assert %{status: :queued, subject_count: 3, seed: 9, captures: 2} = run
      assert run.name =~ ~r/\A\d{8}-\d{6}-seed9\z/
      assert "rolled_01_c2" in run.shots and "tenprint_card_c2" in run.shots

      for position <- 1..3 do
        assert_enqueued(
          worker: GenerateSubject,
          queue: :generation,
          args: %{run_id: run.id, position: position}
        )
      end

      assert_received {:run_updated, %{id: id, status: :queued}} when id == run.id
    end

    test "validates the request" do
      assert {:error, changeset} = Biometrics.create_run(%{subjects: 0, shots: ["selfie"]})
      assert %{subjects: _, shots: _} = Map.new(changeset.errors)
      refute_enqueued(worker: GenerateSubject)
    end
  end

  describe "resuming and cancelling" do
    test "resume queues only the subjects that aren't done" do
      name = create_run(subjects: 2)
      {:ok, run} = Biometrics.get_run(name)
      run |> Ecto.Changeset.change(subject_count: 3) |> Repo.update!()

      assert {:ok, %{status: :queued}} = Biometrics.resume_run(%{run | subject_count: 3})
      assert [%{args: %{"position" => 3}}] = all_enqueued(worker: GenerateSubject)

      render_queued()
      assert {:ok, %{status: :finished, completed_subjects: 3}} = Biometrics.get_run(name)
    end

    test "a subject is queued once while its job is pending" do
      {:ok, run} = Biometrics.create_run(%{subjects: 1, shots: ["rolled_01"]})
      {:ok, _run} = Biometrics.resume_run(run)

      assert [_one] = all_enqueued(worker: GenerateSubject)
    end

    test "cancelling cancels the run's pending jobs" do
      {:ok, run} = Biometrics.create_run(%{subjects: 2, shots: ["rolled_01"]})
      {:ok, other} = Biometrics.create_run(%{subjects: 1, shots: ["rolled_01"]})

      assert {:ok, %{status: :cancelled, finished_at: %DateTime{}}} = Biometrics.cancel_run(run)
      assert [%{args: %{"run_id" => other_id}}] = all_enqueued(worker: GenerateSubject)
      assert other_id == other.id
    end

    test "records why a run failed" do
      {:ok, run} = Biometrics.create_run(%{subjects: 1, shots: ["rolled_01"]})
      assert {:ok, %{status: :failed, error: "boom"}} = Biometrics.fail_run(run.id, "boom")
    end
  end

  describe "progress and events" do
    test "reports the subject being rendered" do
      {:ok, run} = Biometrics.create_run(%{subjects: 2, shots: ["mugshot_frontal"]})
      assert Biometrics.current_progress() == nil

      subject =
        Biometrics.start_subject(run, 1, %{seed: 1, description: "someone", attributes: %{}})

      assert %{run: name, total: 2, done: 0, subject: %{name: "subject_001"}} =
               Biometrics.current_progress()

      assert name == run.name
      Biometrics.complete_subject(subject)
      assert %{done: 1, subject: nil} = Biometrics.current_progress()
    end

    test "broadcasts subjects as they get images and runs as they finish" do
      Biometrics.subscribe()
      name = create_run(subjects: 1)

      assert_received {:run_updated, %{name: ^name, status: :running}}
      assert_received {:subject_updated, %{name: "subject_001", images: []}}
      assert_received {:subject_updated, %{images: [%{shot: "mugshot_frontal"}]}}
      assert_received {:run_updated, %{name: ^name, status: :finished, completed_subjects: 1}}
    end
  end
end
