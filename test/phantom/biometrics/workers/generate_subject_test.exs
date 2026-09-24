defmodule Phantom.Biometrics.Workers.GenerateSubjectTest do
  use Phantom.DataCase, async: true

  import Phantom.BiometricsFixtures

  alias Phantom.Biometrics
  alias Phantom.Biometrics.Workers.GenerateSubject

  test "renders the subject" do
    stub_qwen()
    {:ok, run} = Biometrics.create_run(%{subjects: 1, shots: ["mugshot_frontal"]})

    assert :ok = perform_job(GenerateSubject, %{run_id: run.id, position: 1})
    assert {:ok, %{status: :finished, completed_subjects: 1}} = Biometrics.get_run(run.name)
  end

  test "snoozes while a service it needs isn't ready" do
    Req.Test.stub(Phantom.Services.Ridgegen, &Req.Test.transport_error(&1, :econnrefused))
    {:ok, run} = Biometrics.create_run(%{subjects: 1, shots: ["rolled_01"]})

    assert {:snooze, 30} = perform_job(GenerateSubject, %{run_id: run.id, position: 1})
    assert {:ok, %{status: :queued}} = Biometrics.get_run(run.name)
  end

  test "stops for cancelled and deleted runs" do
    {:ok, run} = Biometrics.create_run(%{subjects: 1, shots: ["rolled_01"]})
    {:ok, _run} = Biometrics.cancel_run(run)

    assert {:cancel, :cancelled} = perform_job(GenerateSubject, %{run_id: run.id, position: 1})
    assert {:cancel, :run_deleted} = perform_job(GenerateSubject, %{run_id: -1, position: 1})
  end

  test "marks the run failed when a job is discarded" do
    {:ok, run} = Biometrics.create_run(%{subjects: 1, shots: ["rolled_01"]})
    job = %Oban.Job{worker: Oban.Worker.to_string(GenerateSubject), args: %{"run_id" => run.id}}

    GenerateSubject.handle_event(
      [:oban, :job, :exception],
      %{},
      %{
        job: job,
        state: :discard,
        kind: :error,
        reason: %RuntimeError{message: "boom"}
      },
      nil
    )

    assert {:ok, %{status: :failed, error: "** (RuntimeError) boom"}} =
             Biometrics.get_run(run.name)
  end
end
