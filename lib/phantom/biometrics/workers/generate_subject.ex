defmodule Phantom.Biometrics.Workers.GenerateSubject do
  @moduledoc """
  Renders one subject of a run (`Phantom.Biometrics.Generator`).

  Jobs run in the `generation` queue, one at a time. A job is unique per run
  and subject while it's incomplete, so resuming twice doesn't render a
  subject twice. A retried job, or one rescued after a restart, picks up where
  it stopped: images already stored are kept. While a service it needs isn't
  ready (the Qwen model can take minutes to load), the job snoozes.

  When a job runs out of attempts, `handle_event/4` marks its run failed.
  """

  use Oban.Worker,
    queue: :generation,
    max_attempts: 3,
    unique: [keys: [:run_id, :position], states: :incomplete]

  alias Phantom.Biometrics
  alias Phantom.Biometrics.Generator

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id, "position" => position}}) do
    case Biometrics.get_run_by_id(run_id) do
      nil ->
        {:cancel, :run_deleted}

      %{status: status} when status in [:cancelled, :finished] ->
        {:cancel, status}

      run ->
        case Biometrics.check_services(run.shots) do
          :ok ->
            Generator.generate_subject(run, position)
            :ok

          {:error, _message} ->
            {:snooze, 30}
        end
    end
  end

  # Below the Lifeline's rescue_after (config.exs), so a job is never rescued
  # while it's still rendering.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(25)

  @doc "Attaches `handle_event/4` to Oban's job exception events."
  def attach_telemetry do
    :telemetry.attach(
      "#{__MODULE__}.discards",
      [:oban, :job, :exception],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  def handle_event(_event, _measurements, %{job: job, state: :discard} = meta, _config) do
    if job.worker == Oban.Worker.to_string(__MODULE__) do
      Biometrics.fail_run(job.args["run_id"], Exception.format_banner(meta.kind, meta.reason))
    end

    :ok
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok
end
