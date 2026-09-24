defmodule Phantom.Biometrics.Runner do
  @moduledoc """
  Runs one `Phantom.Biometrics.Harness` batch at a time in the background and
  broadcasts its progress, so LiveViews can follow a run and the run carries on
  when they go away. One at a time because the Qwen service renders one image at
  a time anyway, and the friction-ridge service already uses every CPU core.

  Subscribers to `topic/0` receive `{:biometrics_run, event, progress}` where `event` is
  `:started`, `:progress` (a subject started or a shot finished), `:subject_done`,
  `:finished`, `:cancelled` or `:failed`, and `progress` is a snapshot:

      %{run: name, seed: seed, shots: [shot_id], total: subjects, done: finished_subjects,
        subject: current_subject_or_nil, status: :running | event, error: message_or_nil}

  `subject` is a `Phantom.Biometrics.Subject` with the images rendered so far.

  The run itself is recorded in the database (`Phantom.Biometrics.Runs`), so
  its status survives restarts: runs interrupted by one are marked cancelled
  when the application starts (`Runs.interrupt_running/0`), ready to be resumed.
  """

  use GenServer

  alias Phantom.Biometrics.{Harness, Runs}

  @topic "biometrics:runs"

  def topic, do: @topic
  def subscribe, do: Phoenix.PubSub.subscribe(Phantom.PubSub, @topic)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Starts a run with `Harness.run/1` options. Resolves the seed and run name up
  front so the caller can link to the run right away.

  Returns `{:ok, run_name}`, `{:error, :busy}` while another run is active, or
  `{:error, message}` for invalid options.
  """
  def start_run(opts), do: GenServer.call(__MODULE__, {:start_run, opts})

  @doc "Cancels the active run, if any. Images already written are kept, so it can be resumed."
  def cancel, do: GenServer.call(__MODULE__, :cancel)

  @doc "The progress snapshot of the active run, or `nil`."
  def current, do: GenServer.call(__MODULE__, :current)

  @impl true
  def init(_opts), do: {:ok, %{task: nil, progress: nil, cancelling?: false}}

  @impl true
  def handle_call({:start_run, _opts}, _from, %{task: %Task{}} = state) do
    {:reply, {:error, :busy}, state}
  end

  # The run is recorded before replying, so the caller can link to it.
  def handle_call({:start_run, opts}, _from, state) do
    case Harness.start(opts) do
      {:ok, run} ->
        runner = self()

        task =
          Task.Supervisor.async_nolink(Phantom.Biometrics.TaskSupervisor, fn ->
            Harness.execute(run, Keyword.put(opts, :on_progress, &send(runner, {:harness, &1})))
          end)

        progress = %{
          run: run.name,
          seed: run.seed,
          shots: run.shots,
          total: run.subject_count,
          done: 0,
          subject: nil,
          status: :running,
          error: nil
        }

        broadcast(:started, progress)
        {:reply, {:ok, run.name}, %{state | task: task, progress: progress, cancelling?: false}}

      {:error, message} ->
        {:reply, {:error, message}, state}
    end
  end

  # The task is gone once terminate_child returns, so the run is recorded as
  # cancelled right away; its :DOWN message only broadcasts it.
  def handle_call(:cancel, _from, %{task: %Task{pid: pid}} = state) do
    Task.Supervisor.terminate_child(Phantom.Biometrics.TaskSupervisor, pid)
    Runs.finish_run_by_name(state.progress.run, "cancelled")
    {:reply, :ok, %{state | cancelling?: true}}
  end

  def handle_call(:cancel, _from, state), do: {:reply, :ok, state}

  def handle_call(:current, _from, state), do: {:reply, state.progress, state}

  @impl true
  def handle_info({:harness, event}, %{progress: %{} = progress} = state) do
    {event_name, progress} = apply_event(event, progress)
    broadcast(event_name, progress)

    # A finished subject is broadcast once with the full record, then dropped.
    progress = if event_name == :subject_done, do: %{progress | subject: nil}, else: progress
    {:noreply, %{state | progress: progress}}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, _result} -> finish(state, :finished, nil)
      {:error, message} -> finish(state, :failed, message)
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    if state.cancelling?,
      do: finish(state, :cancelled, nil),
      else: finish(state, :failed, "Run crashed: #{Exception.format_exit(reason)}")
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp apply_event({:subject_started, subject}, progress) do
    {:progress, %{progress | subject: subject}}
  end

  defp apply_event(
         {:shot, subject_name, image},
         %{subject: %{name: subject_name} = subject} = progress
       ) do
    {:progress, %{progress | subject: %{subject | images: subject.images ++ [image]}}}
  end

  defp apply_event({:shot, _subject_id, _record}, progress), do: {:progress, progress}

  defp apply_event({:subject_done, subject}, progress) do
    {:subject_done, %{progress | subject: subject, done: progress.done + 1}}
  end

  # Finished runs are recorded by the harness and cancelled ones by cancel/0.
  defp finish(state, status, error) do
    if status == :failed, do: Runs.finish_run_by_name(state.progress.run, "failed", error)

    broadcast(status, %{state.progress | status: status, error: error, subject: nil})
    {:noreply, %{state | task: nil, progress: nil, cancelling?: false}}
  end

  defp broadcast(event, progress) do
    Phoenix.PubSub.broadcast(Phantom.PubSub, @topic, {:biometrics_run, event, progress})
  end
end
