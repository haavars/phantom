defmodule Phantom.Biometrics.RunnerTest do
  # The runner is an application-wide singleton running the harness in its own
  # task, so these tests share it and the Req.Test stubs globally.
  use Phantom.DataCase, async: false

  import Phantom.BiometricsFixtures

  alias Phantom.Biometrics.{Runner, Runs, Storage}

  setup {Req.Test, :set_req_test_to_shared}

  setup do
    Runner.subscribe()
    on_exit(fn -> Runner.cancel() end)
  end

  test "runs the harness in the background and broadcasts progress" do
    stub_qwen()

    assert {:ok, "bg-run"} =
             Runner.start_run(
               run: "bg-run",
               seed: 1,
               subjects: 2,
               shots: ["mugshot_frontal"]
             )

    assert_receive {:biometrics_run, :started,
                    %{run: "bg-run", total: 2, shots: ["mugshot_frontal"]}}

    assert_receive {:biometrics_run, :progress, %{subject: %{name: "subject_001", images: []}}}
    assert_receive {:biometrics_run, :progress, %{subject: %{images: [%{status: "ok"}]}}}
    assert_receive {:biometrics_run, :subject_done, %{done: 1, subject: %{name: "subject_001"}}}
    assert_receive {:biometrics_run, :subject_done, %{done: 2, subject: %{name: "subject_002"}}}
    assert_receive {:biometrics_run, :finished, %{run: "bg-run", status: :finished}}

    assert Runner.current() == nil
    assert Storage.exists?("bg-run/subject_002/mugshot_frontal.png")
    assert {:ok, %{status: "finished", completed_subjects: 2}} = Runs.summary("bg-run")
  end

  test "allows one run at a time and can cancel it" do
    test_pid = self()

    stub_qwen(
      generate: fn conn ->
        send(test_pid, :rendering)

        receive do
          :continue -> send_png(conn)
        end
      end
    )

    assert {:ok, "slow-run"} = Runner.start_run(run: "slow-run", subjects: 1)
    assert {:ok, %{status: "running"}} = Runs.summary("slow-run")
    assert_receive :rendering
    assert %{run: "slow-run", status: :running} = Runner.current()

    assert {:error, :busy} = Runner.start_run(run: "other-run")

    assert :ok = Runner.cancel()
    assert_receive {:biometrics_run, :cancelled, %{run: "slow-run"}}
    assert Runner.current() == nil
    assert {:ok, %{status: "cancelled"}} = Runs.summary("slow-run")
    refute Runs.exists?("other-run")
  end

  test "rejects unknown shots without starting a run" do
    assert {:error, message} = Runner.start_run(shots: ["selfie"])
    assert message =~ "selfie"
    refute_received {:biometrics_run, :started, _progress}
  end
end
