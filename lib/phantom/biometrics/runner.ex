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

  `subject` has the same shape as a finished subject, with the shots rendered so far.
  """

  use GenServer

  alias Phantom.Biometrics.Harness

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

  def handle_call({:start_run, opts}, _from, state) do
    case Harness.resolve_shots(
           Keyword.get(opts, :shots, ["faces"]),
           Keyword.get(opts, :captures, 1)
         ) do
      {:ok, shots} ->
        seed = Keyword.get_lazy(opts, :seed, &Harness.random_seed/0)
        run = Keyword.get_lazy(opts, :run, fn -> Harness.default_run_name(seed) end)
        runner = self()

        harness_opts =
          Keyword.merge(opts,
            seed: seed,
            run: run,
            shots: shots,
            on_progress: &send(runner, {:harness, &1})
          )

        task =
          Task.Supervisor.async_nolink(Phantom.Biometrics.TaskSupervisor, fn ->
            Harness.run(harness_opts)
          end)

        progress = %{
          run: run,
          seed: seed,
          shots: shots,
          total: Keyword.get(opts, :subjects, 3),
          done: 0,
          subject: nil,
          status: :running,
          error: nil
        }

        broadcast(:started, progress)
        {:reply, {:ok, run}, %{state | task: task, progress: progress, cancelling?: false}}

      {:error, message} ->
        {:reply, {:error, message}, state}
    end
  end

  def handle_call(:cancel, _from, %{task: %Task{pid: pid}} = state) do
    Task.Supervisor.terminate_child(Phantom.Biometrics.TaskSupervisor, pid)
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
    {:progress, %{progress | subject: Map.put(subject, :shots, [])}}
  end

  defp apply_event(
         {:shot, subject_id, record},
         %{subject: %{id: subject_id} = subject} = progress
       ) do
    {:progress, %{progress | subject: %{subject | shots: subject.shots ++ [record]}}}
  end

  defp apply_event({:shot, _subject_id, _record}, progress), do: {:progress, progress}

  defp apply_event({:subject_done, subject}, progress) do
    {:subject_done, %{progress | subject: subject, done: progress.done + 1}}
  end

  defp finish(state, status, error) do
    broadcast(status, %{state.progress | status: status, error: error, subject: nil})
    {:noreply, %{state | task: nil, progress: nil, cancelling?: false}}
  end

  defp broadcast(event, progress) do
    Phoenix.PubSub.broadcast(Phantom.PubSub, @topic, {:biometrics_run, event, progress})
  end
end
