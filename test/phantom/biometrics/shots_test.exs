defmodule Phantom.Biometrics.ShotsTest do
  use ExUnit.Case, async: true

  alias Phantom.Biometrics.{FacePrompts, Shots}

  test "expands groups in a stable order, with the face anchor only when there are face shots" do
    assert {:ok, ["slap_13", "slap_14", "slap_15"]} = Shots.expand(["slaps"])

    assert {:ok, ["mugshot_frontal", "probe_aged", "palm_21", "palm_22", "palm_23", "palm_24"]} =
             Shots.expand(["palms", "probe_aged"])

    assert {:ok, ids} = Shots.expand(["faces", "rolled"])
    assert Enum.take(ids, length(FacePrompts.default_shots())) == FacePrompts.default_shots()
    assert List.last(ids) == "rolled_10"
  end

  test "adds later captures of friction-ridge shots after the first" do
    assert {:ok, ids} = Shots.expand(["card", "mugshot_right_profile"], 3)

    assert ids == [
             "mugshot_frontal",
             "mugshot_right_profile",
             "tenprint_card",
             "tenprint_card_c2",
             "tenprint_card_c3"
           ]
  end

  test "rejects unknown names" do
    assert {:error, "Unknown shots: iris"} = Shots.expand(["rolled", "iris"])
  end

  test "describes shots across modalities" do
    assert %{modality: :face, code: "L", group: "face", size: {896, 1120}} =
             Shots.spec("mugshot_left_profile")

    assert %{modality: :ridge, kind: "finger", numeric_code: 7, code: "7", capture: 1} =
             Shots.spec("rolled_07_c2")

    assert %{kind: "palm", size: {875, 2500}} = Shots.spec("palm_24")
    assert Shots.spec("rolled_11") == nil
    assert Shots.spec("rolled_01_c9") == nil

    assert Shots.label("rolled_06") == "L thumb"
    assert Shots.label("slap_13_c2") == "Right four · 2"
  end
end
