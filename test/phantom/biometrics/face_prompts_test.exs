defmodule Phantom.Biometrics.FacePromptsTest do
  use ExUnit.Case, async: true

  alias Phantom.Biometrics.{FaceAttributes, FacePrompts}

  test "every shot has a spec and a fully filled-in prompt" do
    attrs = FaceAttributes.sample(99)

    for shot <- FacePrompts.shots() do
      assert %{pos: pos, size: {width, height}, downscale: downscale} = FacePrompts.spec(shot)
      assert pos in ~w(F L R A)
      # The size it's rendered at.
      assert rem(width * downscale, 32) == 0 and rem(height * downscale, 32) == 0

      prompt = FacePrompts.prompt(shot, attrs)
      refute prompt =~ ~r/[{}]|#\{/
      refute String.ends_with?(prompt, "\n")
    end
  end

  test "the low-resolution probe is a mugshot-sized render scaled down to about 40 px IED" do
    %{size: {width, height}, downscale: downscale} = FacePrompts.spec("probe_low_res")
    mugshot = FacePrompts.spec("mugshot_frontal")

    assert {width * downscale, height * downscale} == mugshot.size
    assert mugshot.downscale == 1
    # The mugshots' inter-eye distance is about 150 px.
    assert div(150, downscale) in 30..60
  end

  test "the low-resolution snapshots are taken in many scenes, indoors and out" do
    scenes =
      for seed <- 1..80 do
        attrs = FaceAttributes.sample(seed)
        scene = FacePrompts.snapshot_scene(attrs)
        prompt = FacePrompts.prompt("probe_low_res", attrs)

        assert scene == FacePrompts.snapshot_scene(attrs)
        assert prompt =~ "taken #{scene.place} with a phone camera"
        assert prompt =~ scene.light
        assert prompt =~ "the background is #{scene.background}, slightly out of focus"
        refute prompt =~ "other people"
        scene
      end

    assert scenes |> Enum.uniq() |> length() > 8
    assert Enum.any?(scenes, &(&1.place =~ "outdoors"))
    refute Enum.all?(scenes, &(&1.place =~ "outdoors"))
    assert Enum.count(scenes, &(&1.light =~ "ceiling")) < 20
  end

  test "only the anchor shot is generated from text alone" do
    assert [anchor] = Enum.filter(FacePrompts.shots(), &FacePrompts.spec(&1).anchor?)
    assert anchor == FacePrompts.anchor_shot()
    assert FacePrompts.anchor_shot() in FacePrompts.default_shots()
  end

  test "scars look as on the anchor in the mugshots and have healed in every later shot" do
    later =
      ~w(icao_portrait probe_rebooking probe_uncooperative probe_aged probe_glasses
         probe_appearance probe_low_res)

    session = FacePrompts.shots() -- later

    for mark <- Enum.filter(FaceAttributes.marks(), &(&1 =~ "scar")) do
      attrs = FaceAttributes.sample(5, marks: [mark])

      for shot <- session do
        refute FacePrompts.prompt(shot, attrs) =~ "healed into"
        refute FacePrompts.prompt(shot, attrs) =~ "fully healed"
      end

      for shot <- later do
        prompt = FacePrompts.prompt(shot, attrs)
        assert prompt =~ "fully healed"

        assert prompt =~
                 "Keep the face shape, bone structure, eyes, nose, mouth, ears, skin tone and any moles or freckles exactly the same"
      end
    end

    # Moles and the like carry over unchanged.
    attrs = FaceAttributes.sample(5, marks: ["a small mole on the left cheek"])

    for shot <- later do
      refute FacePrompts.prompt(shot, attrs) =~ "healed"
      assert FacePrompts.prompt(shot, attrs) =~ "any scars, moles or freckles exactly the same"
    end
  end

  test "probes vary head angle and expression slightly, the mugshots and ICAO portrait don't" do
    probes =
      ~w(probe_rebooking probe_uncooperative probe_aged probe_glasses probe_appearance probe_low_res)

    yaws = %{"probe_rebooking" => 1..3, "probe_uncooperative" => 20..35}
    attrs = FaceAttributes.sample(7)

    for shot <- probes do
      prompt = FacePrompts.prompt(shot, attrs)
      v = FacePrompts.variation(shot, attrs)
      assert v.yaw in Map.get(yaws, shot, 4..19)
      assert prompt =~ "the head is turned about #{v.yaw} degrees towards the #{v.towards}"
      assert prompt =~ "the expression changes to #{v.expression}"
      refute prompt =~ "neutral expression"
    end

    for shot <- FacePrompts.shots() -- probes do
      refute FacePrompts.prompt(shot, attrs) =~ "the expression changes to"
    end

    assert FacePrompts.prompt("icao_portrait", attrs) =~ "neutral expression"
  end

  test "the re-booking keeps the booking setup and turns at most a couple of degrees" do
    for seed <- 1..60 do
      attrs = FaceAttributes.sample(seed)
      v = FacePrompts.variation("probe_rebooking", attrs)

      assert v.yaw in 1..3
      assert %{pitch: :level, roll: nil, off_camera?: false} = v
      refute v.expression =~ ~r/broad smile|mouth slightly open/

      prompt = FacePrompts.prompt("probe_rebooking", attrs)
      assert prompt =~ "still almost squarely frontal"
      assert prompt =~ "plain uniform mid-grey background, even diffuse flash lighting"
      refute prompt =~ ~r/fluorescent|messier|wall|closer/
    end

    expressions =
      for seed <- 1..60,
          do: FacePrompts.variation("probe_rebooking", FaceAttributes.sample(seed)).expression

    assert expressions |> Enum.uniq() |> length() > 4
  end

  test "the uncooperative booking is turned well away, pulling a face, and angled" do
    assert FacePrompts.spec("probe_uncooperative").pos == "A"
    refute "probe_uncooperative" in FacePrompts.default_shots()

    variations =
      for seed <- 1..60 do
        attrs = FaceAttributes.sample(seed)
        v = FacePrompts.variation("probe_uncooperative", attrs)
        angle = FacePrompts.pose_angle("probe_uncooperative", attrs)

        assert v.yaw in 20..35
        assert v.pitch in [:up, :down]
        assert angle == if(v.towards == "left", do: -v.yaw, else: v.yaw)

        prompt = FacePrompts.prompt("probe_uncooperative", attrs)
        assert prompt =~ "drunk and disorderly"
        assert prompt =~ "both eyes still visible"
        # A flushed face came out looking like makeup.
        refute prompt =~ ~r/flushed|red across/
        assert prompt =~ "nearer the #{v.towards} edge"
        v
      end

    assert variations |> Enum.map(& &1.expression) |> Enum.uniq() |> length() > 4
    assert Enum.any?(variations, & &1.off_camera?)
    refute Enum.all?(variations, & &1.off_camera?)

    # The ¾ views keep their fixed angle; frontal shots have none.
    attrs = FaceAttributes.sample(1)
    assert FacePrompts.pose_angle("mugshot_three_quarter_left", attrs) == -45
    assert FacePrompts.pose_angle("mugshot_three_quarter_right", attrs) == 45
    assert FacePrompts.pose_angle("probe_rebooking", attrs) == nil
  end

  test "a probe's variation is fixed per person and shot and differs between them" do
    people = for seed <- 1..60, do: FaceAttributes.sample(seed)
    [first | _] = people

    assert FacePrompts.variation("probe_aged", first) ==
             FacePrompts.variation("probe_aged", first)

    refute FacePrompts.variation("probe_aged", first) ==
             FacePrompts.variation("probe_glasses", first)

    variations = Enum.map(people, &FacePrompts.variation("probe_aged", &1))
    assert variations |> Enum.map(& &1.expression) |> Enum.uniq() |> length() > 5
    assert variations |> Enum.map(& &1.towards) |> Enum.uniq() |> Enum.sort() == ["left", "right"]
    assert variations |> Enum.map(& &1.pitch) |> Enum.uniq() |> length() == 3
    assert Enum.any?(variations, & &1.off_camera?)
    refute Enum.all?(variations, & &1.off_camera?)
  end

  test "probes change into clothes for the person's sex, in another colour" do
    changes = %{
      "icao_portrait" => "the clothing is now ",
      "probe_rebooking" => "now wears ",
      "probe_uncooperative" => "now wears ",
      "probe_aged" => "now wears ",
      "probe_glasses" => "now wears ",
      "probe_appearance" => "now wears ",
      "probe_low_res" => "now wears "
    }

    for seed <- 1..80, {shot, lead} <- changes do
      attrs = FaceAttributes.sample(seed)
      prompt = FacePrompts.prompt(shot, attrs)

      # The item the probe changes into ends that change (";" or ".").
      assert [item] =
               Enum.filter(FaceAttributes.clothing(), fn item ->
                 String.contains?(prompt, lead <> item <> ";") or
                   String.contains?(prompt, lead <> item <> ".")
               end)

      assert item in FaceAttributes.clothing(attrs.sex)

      refute FaceAttributes.clothing_colour(item) ==
               FaceAttributes.clothing_colour(attrs.clothing)
    end
  end

  test "the aged probe ages people as much as the age they reach, and no more" do
    aged = fn age, opts ->
      attrs = %{FaceAttributes.sample(3, opts) | age: age}
      FacePrompts.prompt("probe_aged", attrs)
    end

    # 18 to 33: maturing, not wrinkles, grey hair or age spots.
    young = aged.(18, sex: :female)
    assert young =~ "now 33 years old"
    assert young =~ "only subtle, natural maturing for someone of 33"
    assert young =~ "with no grey"
    assert young =~ "She must look 33, no older"
    refute young =~ "crow's feet"
    refute young =~ ~r/greyer|thinner|age spots,/

    middle = aged.(30, [])
    assert middle =~ "moderate, realistic ageing for someone of 45"
    assert middle =~ "a few grey strands" or middle =~ "a little whiter"

    older = aged.(40, [])
    assert older =~ "clear ageing for someone of 55"
    refute older =~ "a few age spots"

    oldest = aged.(60, hair_color: "black")
    assert oldest =~ "strong ageing for someone of 75"
    assert oldest =~ "a few age spots"
    assert oldest =~ "mostly grey and thinner"
  end

  test "the anchor prompt describes the person, conditioned shots refer to the reference" do
    attrs = FaceAttributes.sample(5)

    assert FacePrompts.prompt("mugshot_frontal", attrs) =~ FaceAttributes.describe(attrs)
    assert FacePrompts.prompt("mugshot_left_profile", attrs) =~ "reference image"
    assert FacePrompts.prompt("mugshot_left_profile", attrs) =~ "faces the left edge"
    assert FacePrompts.prompt("mugshot_right_profile", attrs) =~ "faces the right edge"
  end
end
