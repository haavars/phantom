defmodule Mix.Tasks.Biometrics.Generate do
  @shortdoc "Generates synthetic subjects: faces (Qwen-Image-2.1), fingerprints and palmprints"

  @moduledoc """
  Generates synthetic subjects, see `Bilder.Biometrics.Harness`.

      mix biometrics.generate --subjects 5
      mix biometrics.generate --shots rolled,slaps,palms,card --captures 2
      mix biometrics.generate --shots faces,rolled --seed 42
      mix biometrics.generate --run my-run --seed 42 --subjects 10   # resumes my-run

  Options:

    * `--subjects` - number of subjects (default 3)
    * `--seed` - run seed (default random); same seed + same run name resumes a run
    * `--shots` - comma-separated shot ids and groups (default: faces). Groups: `faces`
      (#{Enum.join(Bilder.Biometrics.FacePrompts.default_shots(), ", ")}), `rolled`, `slaps`,
      `palms`, `card`. Face shots: #{Enum.join(Bilder.Biometrics.FacePrompts.shots(), ", ")}
    * `--captures` - captures per finger and palm shot, for mated pairs (default 1, max 3)
    * `--steps` - denoising steps for face shots (default 40)
    * `--out` - output root (default `config :bilder, :biometrics_output_dir`, data/synthetic/biometrics)
    * `--run` - run directory name (default `<timestamp>-seed<seed>`)
    * `--force` - regenerate images that already exist

  Face shots need the Qwen-Image-2.1 service and friction-ridge shots the
  python_biometrics service; both start with `mix phx.server`. This task only
  loads config, so it doesn't start second copies of them.
  """

  use Mix.Task

  alias Bilder.Biometrics.{FrictionRidge, Harness, Shots}
  alias Bilder.ImageGeneration

  @switches [
    subjects: :integer,
    seed: :integer,
    shots: :string,
    captures: :integer,
    steps: :integer,
    out: :string,
    run: :string,
    force: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}. See `mix help biometrics.generate`.")
    end

    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:req)

    opts =
      opts
      |> Keyword.update(:shots, nil, &String.split(&1, ",", trim: true))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Keyword.put(:on_progress, &report/1)

    case Harness.resolve_shots(
           Keyword.get(opts, :shots, ["faces"]),
           Keyword.get(opts, :captures, 1)
         ) do
      {:ok, shots} -> check_services(shots)
      {:error, message} -> Mix.raise(message)
    end

    case Harness.run(opts) do
      {:ok, %{index: index}} -> Mix.shell().info("\nContact sheet: #{Path.expand(index)}")
      {:error, message} -> Mix.raise(message)
    end
  end

  defp check_services(shots) do
    if Enum.any?(shots, &Shots.face?/1) and ImageGeneration.health() != :ready do
      Mix.raise("The Qwen-Image-2.1 service isn't ready: #{inspect(ImageGeneration.health())}")
    end

    if Enum.any?(shots, &Shots.ridge?/1) and FrictionRidge.health() != :ready do
      Mix.raise("The friction-ridge service isn't ready: #{inspect(FrictionRidge.health())}")
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
