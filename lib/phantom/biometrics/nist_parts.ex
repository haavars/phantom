defmodule Phantom.Biometrics.NistParts do
  @moduledoc """
  The records a print or palm becomes in a NIST export: `[{position, area}]`,
  where `area` is `nil` for the whole image or `{left, top, width, height}`.

  The ANSI/NIST target exports every image as it is. Unify doesn't accept
  the two-thumb slap (FGP 15) or full palms (PLP 21, 23), so its target cuts
  them into positions it does (`docs/phantom_an2_unify_import.md` §3.2):

    * **Two thumbs** into plain thumbs, FGP 11 (right) and 12 (left). The
      slap has one thumb in each half: the left thumb (finger 6) on the left.
      Each is the largest image the standard allows, 1.0 × 2.0 in (500 × 1000
      px at 500 ppi), centred on the thumb's ground-truth minutiae and
      starting just above the topmost.
    * **Full palms** into upper and lower palms, PLP 26/25 (right) and 28/27
      (left), at most 5.5 × 5.5 in (2750 × 2750 px) each. The cut lies
      halfway between the lowest interdigital triradius (`a`–`d`, below the
      fingers) and the thenar/hypothenar one (`t`), and each part runs
      0.5 in past it, so they overlap by an inch.

  Without ground truth, the thumbs are the slap's halves and the palm is cut
  in the middle.
  """

  alias Phantom.Biometrics.Shots

  @ppi 500
  @thumb_max {@ppi, @ppi * 2}
  @thumb_margin 100
  @palm_max div(@ppi * 11, 2)
  @palm_overlap div(@ppi, 2)

  # FGP 15 -> {right thumb, left thumb}; PLP 21/23 -> {upper, lower}.
  @thumbs {11, 12}
  @palms %{21 => {26, 25}, 23 => {28, 27}}

  @doc "`image`'s records for `target` (`\"ansi_nist\"` or `\"unify\"`)."
  def parts(image, target) do
    code = Shots.spec(image.shot).numeric_code

    cond do
      target == "unify" and code == 15 -> thumbs(image)
      target == "unify" and Map.has_key?(@palms, code) -> palm(image, @palms[code])
      true -> [{code, nil}]
    end
  end

  defp thumbs(%{width: width, height: height} = image) do
    half = div(width, 2)
    minutiae = (image.ground_truth || %{})["minutiae"] || []
    {right, left} = @thumbs

    [
      {right, thumb(Enum.filter(minutiae, &(&1["x"] >= half)), {half, width}, height)},
      {left, thumb(Enum.filter(minutiae, &(&1["x"] < half)), {0, half}, height)}
    ]
  end

  # The largest plain-thumb image the standard allows, inside the half:
  # centred across on the thumb's minutiae, from just above the topmost down.
  # Ridges reach well past the outermost minutiae, and white margin does no
  # harm, so a tighter box would only cut ridges off.
  defp thumb(minutiae, {x0, x1}, height) do
    {max_w, max_h} = @thumb_max
    width = min(max_w, x1 - x0)

    {centre, top} =
      case minutiae do
        [] ->
          {div(x0 + x1, 2), 0}

        _ ->
          {min_x, max_x} = minutiae |> Enum.map(&trunc(&1["x"])) |> Enum.min_max()
          min_y = minutiae |> Enum.map(&trunc(&1["y"])) |> Enum.min()
          {div(min_x + max_x, 2), max(min_y - @thumb_margin, 0)}
      end

    left = (centre - div(width, 2)) |> max(x0) |> min(x1 - width)
    {left, top, width, min(max_h, height - top)}
  end

  defp palm(%{width: width, height: height} = image, {upper, lower}) do
    cut = palm_cut(image.ground_truth, height)
    upper_height = min(cut + @palm_overlap, @palm_max)
    lower_top = max(cut - @palm_overlap, height - @palm_max)

    [
      {upper, {0, 0, width, upper_height}},
      {lower, {0, lower_top, width, height - lower_top}}
    ]
  end

  defp palm_cut(%{"triradii" => %{"t" => [_, t]} = triradii}, _height) do
    interdigital = for key <- ~w(a b c d), [_, y] <- [triradii[key]], do: y

    case interdigital do
      [] -> trunc(t / 2)
      ys -> trunc((Enum.max(ys) + t) / 2)
    end
  end

  defp palm_cut(_ground_truth, height), do: div(height, 2)
end
