defmodule Phantom.Biometrics.Gallery do
  @moduledoc """
  The synthetic identities across all runs, for the landing page gallery.

  Each identity is one finished subject: its portrait (if it has face shots),
  its rolled prints and their pattern classes, and how many images of each
  modality it has. Newest runs come first.
  """

  alias Phantom.Biometrics.{Runs, Shots}

  @portraits ["mugshot_frontal.png", "icao_portrait.png"]

  @doc "Identities across all runs under `root`, newest first, at most `limit`."
  def identities(limit \\ 48, root \\ Runs.root()) do
    root
    |> Runs.list_runs()
    |> Stream.flat_map(fn summary ->
      case Runs.get_run(summary.name, root) do
        {:ok, run} -> Enum.map(run.subjects_list, &identity(run, &1))
        {:error, :not_found} -> []
      end
    end)
    |> Stream.reject(&(&1.images == 0))
    |> Enum.take(limit)
  end

  @doc "Totals for a list of identities: `:identities`, `:images`, `:faces`, `:prints`, `:runs`."
  def stats(identities) do
    %{
      identities: length(identities),
      images: Enum.sum_by(identities, & &1.images),
      faces: Enum.count(identities, & &1.portrait),
      prints: Enum.count(identities, &(&1.prints != [])),
      runs: identities |> Enum.uniq_by(& &1.run) |> length()
    }
  end

  defp identity(run, subject) do
    shots = Enum.filter(subject.shots, &(&1.status in ["ok", "existing"] and is_binary(&1.file)))
    specs = Enum.map(shots, &{&1, Shots.spec(&1.shot)})
    files = MapSet.new(shots, & &1.file)

    rolled =
      for {shot, %{group: "rolled", capture: 0, numeric_code: fgp}} <- specs,
          do: %{fgp: fgp, file: shot.file, pattern: shot.meta && shot.meta["pattern"]}

    rolled = Enum.sort_by(rolled, & &1.fgp)
    attributes = subject.attributes

    %{
      id: "#{run.name}--#{subject.id}",
      run: run.name,
      subject: subject.id,
      code: code(subject.seed),
      seed: subject.seed,
      description: subject.description,
      sex: attributes["sex"],
      age: attributes["age"],
      portrait: Enum.find(@portraits, &MapSet.member?(files, &1)),
      prints: rolled,
      counts: counts(specs),
      images: length(shots),
      renderer: run.renderer
    }
  end

  defp counts(specs) do
    specs
    |> Enum.frequencies_by(fn {_shot, spec} -> spec && spec.group end)
    |> Map.delete(nil)
  end

  # A stable, readable identity code from the subject seed: PH-3A9F-12C4.
  defp code(seed) when is_integer(seed) do
    hex = seed |> rem(0x100000000) |> Integer.to_string(16) |> String.pad_leading(8, "0")
    "PH-" <> String.slice(hex, 0, 4) <> "-" <> String.slice(hex, 4, 4)
  end

  defp code(_seed), do: "PH-????-????"
end
