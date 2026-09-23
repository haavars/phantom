defmodule Bilder.Biometrics.FacePromptsTest do
  use ExUnit.Case, async: true

  alias Bilder.Biometrics.{FaceAttributes, FacePrompts}

  test "every shot has a spec and a fully filled-in prompt" do
    attrs = FaceAttributes.sample(99)

    for shot <- FacePrompts.shots() do
      assert %{pos: pos, size: {width, height}} = FacePrompts.spec(shot)
      assert pos in ~w(F L R A)
      assert rem(width, 32) == 0 and rem(height, 32) == 0

      prompt = FacePrompts.prompt(shot, attrs)
      refute prompt =~ ~r/[{}]|#\{/
      refute String.ends_with?(prompt, "\n")
    end
  end

  test "only the anchor shot is generated from text alone" do
    assert [anchor] = Enum.filter(FacePrompts.shots(), &FacePrompts.spec(&1).anchor?)
    assert anchor == FacePrompts.anchor_shot()
    assert FacePrompts.anchor_shot() in FacePrompts.default_shots()
  end

  test "the anchor prompt describes the person, conditioned shots refer to the reference" do
    attrs = FaceAttributes.sample(5)

    assert FacePrompts.prompt("mugshot_frontal", attrs) =~ FaceAttributes.describe(attrs)
    assert FacePrompts.prompt("mugshot_left_profile", attrs) =~ "reference image"
    assert FacePrompts.prompt("mugshot_left_profile", attrs) =~ "faces the left edge"
    assert FacePrompts.prompt("mugshot_right_profile", attrs) =~ "faces the right edge"
  end
end
