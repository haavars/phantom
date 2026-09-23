defmodule Bilder.Biometrics.FaceRunnerTest do
  # The runner is an application-wide singleton running the harness in its own
  # task, so these tests share it and the Req.Test stubs globally.
  use ExUnit.Case, async: false

  import Bilder.FaceFixtures

  alias Bilder.Biometrics.FaceRunner

  @moduletag :tmp_dir

  setup {Req.Test, :set_req_test_to_shared}

  setup do
    FaceRunner.subscribe()
    on_exit(fn -> FaceRunner.cancel() end)
  end

  test "runs the harness in the background and broadcasts progress", %{tmp_dir: root} do
    stub_qwen()

    assert {:ok, "bg-run"} =
             FaceRunner.start_run(out: root, run: "bg-run", seed: 1, subjects: 2, shots: [])

    assert_receive {:face_run, :started, %{run: "bg-run", total: 2, shots: ["mugshot_frontal"]}}
    assert_receive {:face_run, :progress, %{subject: %{id: "subject_001", shots: []}}}
    assert_receive {:face_run, :progress, %{subject: %{shots: [%{status: "ok"}]}}}
    assert_receive {:face_run, :subject_done, %{done: 1, subject: %{id: "subject_001"}}}
    assert_receive {:face_run, :subject_done, %{done: 2, subject: %{id: "subject_002"}}}
    assert_receive {:face_run, :finished, %{run: "bg-run", status: :finished}}

    assert FaceRunner.current() == nil
    assert File.exists?(Path.join([root, "bg-run", "subject_002", "mugshot_frontal.png"]))
  end

  test "allows one run at a time and can cancel it", %{tmp_dir: root} do
    test_pid = self()

    stub_qwen(
      generate: fn conn ->
        send(test_pid, :rendering)

        receive do
          :continue -> send_png(conn)
        end
      end
    )

    assert {:ok, "slow-run"} = FaceRunner.start_run(out: root, run: "slow-run", subjects: 1)
    assert_receive :rendering
    assert %{run: "slow-run", status: :running} = FaceRunner.current()

    assert {:error, :busy} = FaceRunner.start_run(out: root, run: "other-run")

    assert :ok = FaceRunner.cancel()
    assert_receive {:face_run, :cancelled, %{run: "slow-run"}}
    assert FaceRunner.current() == nil
  end

  test "rejects unknown shots without starting a run", %{tmp_dir: root} do
    assert {:error, message} = FaceRunner.start_run(out: root, shots: ["selfie"])
    assert message =~ "selfie"
    refute_received {:face_run, :started, _progress}
  end
end
