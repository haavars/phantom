defmodule Phantom.Biometrics.Workers.UploadShare do
  @moduledoc """
  Uploads one share's export to the S3 bucket (`Phantom.Biometrics.Shares`).

  Jobs run in the `transfers` queue, apart from the GPU's `generation` queue.
  A failed upload is retried twice; after the last attempt the share is
  marked failed with the reason.
  """

  use Oban.Worker,
    queue: :transfers,
    max_attempts: 3,
    unique: [keys: [:share_id], states: :incomplete]

  alias Phantom.Biometrics.{Share, Shares}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"share_id" => id}} = job) do
    case Shares.get(id) do
      nil ->
        {:cancel, :share_deleted}

      %Share{status: :ready} ->
        :ok

      share ->
        case upload(share) do
          {:ok, _share} ->
            :ok

          {:error, reason} ->
            Shares.failed(share, reason, job.attempt >= job.max_attempts)
            {:error, reason}
        end
    end
  end

  # A crash building the export (a file deleted meanwhile, say) fails the
  # share like any other error, instead of leaving it "uploading".
  defp upload(share) do
    Shares.upload(share)
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: 15 * attempt

  # Below the Lifeline's rescue_after (config.exs).
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(20)
end
