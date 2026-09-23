defmodule Mix.Tasks.Biometrics.Faces do
  @shortdoc "Generates synthetic mugshots, ICAO portraits and probe images with Qwen-Image-2.1"

  @moduledoc """
  Generates synthetic face images for evaluating prompts, see `Bilder.Biometrics.FaceHarness`.

      mix biometrics.faces --subjects 5
      mix biometrics.faces --subjects 5 --seed 42 --shots mugshot_left_profile,probe_glasses
      mix biometrics.faces --run my-run --seed 42 --subjects 10   # resumes my-run

  Options:

    * `--subjects` - number of subjects (default 3)
    * `--seed` - run seed (default random); same seed + same run name resumes a run
    * `--shots` - comma-separated shot ids (default: #{Enum.join(Bilder.Biometrics.FacePrompts.default_shots(), ",")});
      all: #{Enum.join(Bilder.Biometrics.FacePrompts.shots(), ",")}
    * `--steps` - denoising steps (default 40)
    * `--out` - output root (default `config :bilder, :face_output_dir`, data/synthetic/faces)
    * `--run` - run directory name (default `<timestamp>-seed<seed>`)
    * `--force` - regenerate images that already exist

  Needs the Qwen-Image-2.1 service to be running (it starts with `mix phx.server`).
  This task only loads config, so it doesn't start a second copy of the service.
  """

  use Mix.Task

  alias Bilder.Biometrics.FaceHarness
  alias Bilder.ImageGeneration

  @switches [
    subjects: :integer,
    seed: :integer,
    shots: :string,
    steps: :integer,
    out: :string,
    run: :string,
    force: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}. See `mix help biometrics.faces`.")
    end

    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:req)

    case ImageGeneration.health() do
      :ready -> :ok
      other -> Mix.raise("Qwen-Image-2.1 service isn't ready: #{inspect(other)}")
    end

    opts =
      opts
      |> Keyword.update(:shots, nil, &String.split(&1, ",", trim: true))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Keyword.put(:on_progress, &report/1)

    case FaceHarness.run(opts) do
      {:ok, %{index: index}} -> Mix.shell().info("\nContact sheet: #{Path.expand(index)}")
      {:error, message} -> Mix.raise(message)
    end
  end

  defp report({:subject_started, _subject}), do: :ok

  defp report({:shot, subject_id, %{status: "ok"} = record}) do
    Mix.shell().info("#{subject_id} #{record.shot}: #{record.duration_ms} ms")
  end

  defp report({:shot, subject_id, record}) do
    Mix.shell().info("#{subject_id} #{record.shot}: #{record.status} #{record.error}")
  end

  defp report({:subject_done, subject}) do
    Mix.shell().info("#{subject.id} done: #{subject.description}")
  end
end
