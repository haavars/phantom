defmodule Phantom.Biometrics.Gallery do
  @moduledoc """
  The synthetic identities across all runs, for the landing page gallery.

  Each identity is one subject with at least one rendered image: its portrait
  (if it has face shots), its rolled prints and their pattern classes, and how
  many images of each modality it has. Newest runs come first.
  """

  import Ecto.Query

  alias Phantom.Repo
  alias Phantom.Biometrics.{Image, Shots, Subject}

  @portraits ["mugshot_frontal", "icao_portrait"]

  @doc "Identities across all runs, newest first, at most `limit`."
  def identities(limit \\ 48) do
    rendered = from i in Image, where: i.status == :ok, select: i.subject_id

    Repo.all(
      from s in Subject,
        join: r in assoc(s, :run),
        where: s.id in subquery(rendered),
        order_by: [desc: r.inserted_at, desc: r.id, asc: s.position],
        limit: ^limit,
        preload: [:images, run: r]
    )
    |> Enum.map(&identity/1)
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

  defp identity(subject) do
    images = Enum.filter(subject.images, &Image.rendered?/1)
    specs = Enum.map(images, &{&1, Shots.spec(&1.shot)})
    by_shot = Map.new(images, &{&1.shot, &1})

    prints =
      for {image, %{group: "rolled", capture: 0, numeric_code: fgp}} <- specs do
        %{fgp: fgp, image: image, pattern: image.meta && image.meta["pattern"]}
      end

    attributes = subject.attributes || %{}

    %{
      id: "#{subject.run.name}--#{subject.name}",
      run: subject.run.name,
      subject: subject.name,
      code: code(subject.seed),
      seed: subject.seed,
      description: subject.description,
      sex: attributes["sex"],
      age: attributes["age"],
      portrait: Enum.find_value(@portraits, &by_shot[&1]),
      prints: Enum.sort_by(prints, & &1.fgp),
      counts: counts(specs),
      images: length(images),
      renderer: subject.run.renderer
    }
  end

  defp counts(specs) do
    specs
    |> Enum.frequencies_by(fn {_image, spec} -> spec && spec.group end)
    |> Map.delete(nil)
  end

  @doc "A stable, readable identity code from a subject seed: `PH-3A9F-12C4`."
  def code(seed) when is_integer(seed) do
    hex = seed |> rem(0x100000000) |> Integer.to_string(16) |> String.pad_leading(8, "0")
    "PH-" <> String.slice(hex, 0, 4) <> "-" <> String.slice(hex, 4, 4)
  end

  def code(_seed), do: "PH-????-????"
end
