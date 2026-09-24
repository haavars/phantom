defmodule Phantom.Biometrics.Shots do
  @moduledoc """
  Every kind of image a synthetic subject can have, across modalities.

    * face shots come from `Phantom.Biometrics.FacePrompts` (Qwen-Image-2.1)
    * friction-ridge shots (fingers, slaps, palms, the tenprint card) come from
      `Phantom.Services.Ridgegen`

  Friction-ridge shots can have several captures: `rolled_03` is the first
  capture of the right middle finger, `rolled_03_c2` a second one of the same
  finger, for mated-pair tests.

  Requests can name shots directly or by group: `"faces"` (the default face
  shots), `"rolled"`, `"slaps"`, `"palms"` and `"card"`. `expand/2` turns them
  into the ordered list of shot ids a subject will get.
  """

  alias Phantom.Biometrics.FacePrompts

  @finger_names %{
    1 => "R thumb",
    2 => "R index",
    3 => "R middle",
    4 => "R ring",
    5 => "R little",
    6 => "L thumb",
    7 => "L index",
    8 => "L middle",
    9 => "L ring",
    10 => "L little"
  }

  @ridge_shots (for f <- 1..10 do
                  %{
                    id: "rolled_" <> String.pad_leading(Integer.to_string(f), 2, "0"),
                    group: "rolled",
                    kind: "finger",
                    code: f,
                    size: {800, 750},
                    label: @finger_names[f]
                  }
                end) ++
                 [
                   %{
                     id: "slap_13",
                     group: "slaps",
                     kind: "slap",
                     code: 13,
                     size: {1600, 1500},
                     label: "Right four"
                   },
                   %{
                     id: "slap_14",
                     group: "slaps",
                     kind: "slap",
                     code: 14,
                     size: {1600, 1500},
                     label: "Left four"
                   },
                   %{
                     id: "slap_15",
                     group: "slaps",
                     kind: "slap",
                     code: 15,
                     size: {1600, 1500},
                     label: "Two thumbs"
                   },
                   %{
                     id: "palm_21",
                     group: "palms",
                     kind: "palm",
                     code: 21,
                     size: {2750, 4000},
                     label: "R full palm"
                   },
                   %{
                     id: "palm_22",
                     group: "palms",
                     kind: "palm",
                     code: 22,
                     size: {875, 2500},
                     label: "R writer's palm"
                   },
                   %{
                     id: "palm_23",
                     group: "palms",
                     kind: "palm",
                     code: 23,
                     size: {2750, 4000},
                     label: "L full palm"
                   },
                   %{
                     id: "palm_24",
                     group: "palms",
                     kind: "palm",
                     code: 24,
                     size: {875, 2500},
                     label: "L writer's palm"
                   },
                   %{
                     id: "tenprint_card",
                     group: "card",
                     kind: "card",
                     code: nil,
                     size: {4000, 4000},
                     label: "Tenprint card"
                   }
                 ]

  @face_labels %{
    "mugshot_frontal" => "Frontal",
    "mugshot_left_profile" => "Left profile",
    "mugshot_right_profile" => "Right profile",
    "mugshot_three_quarter_left" => "¾ left",
    "mugshot_three_quarter_right" => "¾ right",
    "icao_portrait" => "ICAO portrait",
    "probe_rebooking" => "Re-booking",
    "probe_aged" => "Aged +15",
    "probe_glasses" => "Glasses",
    "probe_appearance" => "Appearance"
  }

  @groups %{
    "rolled" => "Rolled fingers",
    "slaps" => "Slaps",
    "palms" => "Palms",
    "card" => "Tenprint card"
  }

  @max_captures 3

  def max_captures, do: @max_captures

  @doc "Friction-ridge group ids in display order, with their names."
  def ridge_groups, do: Enum.map(~w(rolled slaps palms card), &{&1, @groups[&1]})

  @doc "Group name for display: `\"Face\"`, `\"Rolled fingers\"`, ..."
  def group_name("face"), do: "Face"
  def group_name(group), do: Map.get(@groups, group, group)

  @doc """
  The spec for a shot id, or `nil`: `:id`, `:modality` (`:face` / `:ridge`),
  `:group`, `:code` (display code: face pose F/L/R/A, FGP or PLP number),
  `:size`, `:capture` (0-based), `:label`, and for ridge shots `:kind`.
  """
  def spec(id) when is_binary(id) do
    case FacePrompts.spec(id) do
      %{} = face ->
        %{
          id: id,
          modality: :face,
          group: "face",
          code: face.pos,
          size: face.size,
          capture: 0,
          label: Map.get(@face_labels, id, id),
          anchor?: face.anchor?
        }

      nil ->
        ridge_spec(id)
    end
  end

  def spec(_id), do: nil

  defp ridge_spec(id) do
    {base, capture} =
      case Regex.run(~r/\A(.+)_c(\d)\z/, id) do
        [_, base, n] -> {base, String.to_integer(n) - 1}
        nil -> {id, 0}
      end

    with true <- capture in 0..(@max_captures - 1),
         %{} = shot <- Enum.find(@ridge_shots, &(&1.id == base)) do
      shot
      |> Map.merge(%{
        id: id,
        modality: :ridge,
        capture: capture,
        anchor?: false,
        code: shot.code && Integer.to_string(shot.code),
        numeric_code: shot.code
      })
    else
      _ -> nil
    end
  end

  def label(id) do
    case spec(id) do
      %{capture: 0, label: label} -> label
      %{capture: capture, label: label} -> "#{label} · #{capture + 1}"
      nil -> id
    end
  end

  def face?(id), do: match?(%{modality: :face}, spec(id))
  def ridge?(id), do: match?(%{modality: :ridge}, spec(id))

  @doc """
  Expands shot ids and group names into the ordered shot ids a subject gets:
  the face anchor first (only when there are face shots), then face shots, then
  friction-ridge shots for capture 1, capture 2, ... up to `captures`.

  Returns `{:ok, ids}` or `{:error, message}` for unknown names.
  """
  def expand(requested, captures \\ 1) do
    captures = captures |> max(1) |> min(@max_captures)

    {ids, unknown} =
      requested
      |> Enum.flat_map(&expand_name/1)
      |> Enum.split_with(&is_tuple/1)

    case unknown do
      [] ->
        ids = Enum.map(ids, fn {:ok, id} -> id end)
        faces = Enum.filter(ids, &face?/1)
        faces = if faces == [], do: [], else: [FacePrompts.anchor_shot() | faces]

        ridge =
          for capture <- 0..(captures - 1),
              base <- Enum.filter(ids, &ridge?/1),
              do: with_capture(base, capture)

        {:ok, Enum.uniq(order(faces) ++ order(ridge))}

      unknown ->
        {:error, "Unknown shots: #{Enum.join(Enum.uniq(unknown), ", ")}"}
    end
  end

  defp expand_name("faces"), do: Enum.map(FacePrompts.default_shots(), &{:ok, &1})

  defp expand_name(group) when is_map_key(@groups, group) do
    for shot <- @ridge_shots, shot.group == group, do: {:ok, shot.id}
  end

  defp expand_name(id) do
    if spec(id), do: [{:ok, id}], else: [id]
  end

  defp with_capture(id, 0), do: id
  defp with_capture(id, capture), do: "#{String.replace(id, ~r/_c\d\z/, "")}_c#{capture + 1}"

  # Faces in FacePrompts order; ridge shots by capture, then registry order.
  defp order(ids) do
    face_order = FacePrompts.shots()
    ridge_order = Enum.map(@ridge_shots, & &1.id)

    Enum.sort_by(ids, fn id ->
      case spec(id) do
        %{modality: :face} ->
          {0, 0, Enum.find_index(face_order, &(&1 == id))}

        %{capture: capture} = spec ->
          {1, capture, Enum.find_index(ridge_order, &(&1 == base_id(spec)))}
      end
    end)
  end

  defp base_id(%{id: id}), do: String.replace(id, ~r/_c\d\z/, "")
end
