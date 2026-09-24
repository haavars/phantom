defmodule Mix.Tasks.Biometrics.Generate do
  @shortdoc "Generates synthetic subjects: faces (Qwen-Image-2.1), fingerprints and palmprints"

  @moduledoc """
  Generates synthetic subjects, see `Phantom.Biometrics.Harness`.

      mix biometrics.generate --subjects 5
      mix biometrics.generate --shots rolled,slaps,palms,card --captures 2
      mix biometrics.generate --shots faces,rolled --seed 42
      mix biometrics.generate --run my-run --seed 42 --subjects 10   # resumes my-run

  Options:

    * `--subjects` - number of subjects (default 3)
    * `--seed` - run seed (default random); same seed + same run name resumes a run
    * `--shots` - comma-separated shot ids and groups (default: faces). Groups: `faces`
      (#{Enum.join(Phantom.Biometrics.FacePrompts.default_shots(), ", ")}), `rolled`, `slaps`,
      `palms`, `card`. Face shots: #{Enum.join(Phantom.Biometrics.FacePrompts.shots(), ", ")}
    * `--captures` - captures per finger and palm shot, for mated pairs (default 1, max 3)
    * `--renderer` - friction-ridge renderer: `diffusion` (realistic, GPU; default) or
      `procedural` (fast CPU draft)
    * `--steps` - denoising steps for face shots (default 40)
    * `--out` - output root (default `config :phantom, :biometrics_output_dir`, data/synthetic/biometrics)
    * `--run` - run directory name (default `<timestamp>-seed<seed>`)
    * `--force` - regenerate images that already exist

  Face shots need the Qwen-Image-2.1 service and friction-ridge shots the
  python_biometrics service; both start with `mix phx.server`. This task only
  loads config, so it doesn't start second copies of them.
  """

  use Mix.Task

  alias Phantom.Biometrics.{FrictionRidge, Harness, Shots}
  alias Phantom.ImageGeneration

  @switches [
    subjects: :integer,
    seed: :integer,
    shots: :string,
    captures: :integer,
    renderer: :string,
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

    renderer = Keyword.get(opts, :renderer, hd(Harness.renderers()))

    if renderer not in Harness.renderers() do
      Mix.raise("--renderer must be one of: #{Enum.join(Harness.renderers(), ", ")}")
    end

    case Harness.resolve_shots(
           Keyword.get(opts, :shots, ["faces"]),
           Keyword.get(opts, :captures, 1)
         ) do
      {:ok, shots} -> check_services(shots)
      {:error, message} -> Mix.raise(message)
    end

    case Harness.run(opts) do
      {:ok, %{index: index, report: report}} ->
        print_report(report)
        Mix.shell().info("\nContact sheet: #{Path.expand(index)}")

      {:error, message} ->
        Mix.raise(message)
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

  defp print_report(nil), do: :ok

  defp print_report(%{"verification" => check} = report) do
    Mix.shell().info(
      "\nVerified #{check["verified"]} friction-ridge images: #{check["accepted"]} accepted, " <>
        "#{check["retried"]} accepted after a retry, #{check["rejected"]} rejected"
    )

    for {impression, row} <- Enum.sort(check["by_impression"]) do
      Mix.shell().info(
        "  #{impression}: NFIQ 2 mean #{row["nfiq2"]["mean"]} " <>
          "(#{row["nfiq2"]["min"]}-#{row["nfiq2"]["max"]}), " <>
          "minutiae recall #{row["minutiae_recall"]["mean"]}"
      )
    end

    case report["matching"] do
      %{"mated" => mated, "non_mated" => non_mated} = matching ->
        Mix.shell().info(
          "  bozorth3: mated #{mated["count"]} pairs, min #{mated["min"] || "-"}; " <>
            "non-mated #{non_mated["count"]} pairs, max #{non_mated["max"] || "-"}; " <>
            "#{matching["false_non_matches"]} mated and #{matching["false_matches"]} " <>
            "non-mated on the wrong side of #{report["threshold"]}"
        )

      %{"error" => message} ->
        Mix.shell().info("  bozorth3 matching failed: #{message}")

      nil ->
        :ok
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
