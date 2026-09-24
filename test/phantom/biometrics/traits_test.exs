defmodule Phantom.Biometrics.TraitsTest do
  use ExUnit.Case, async: true

  alias Phantom.Biometrics.{FaceAttributes, Traits}

  defp cast(params), do: params |> Traits.changeset() |> Ecto.Changeset.apply_action(:insert)

  defp sample(seed, stored), do: FaceAttributes.sample(seed, Traits.sample_opts(stored))

  test "leaves blank traits random" do
    assert {:ok, traits} = cast(%{"sex" => "", "ancestry" => "", "age_min" => ""})
    assert Traits.to_map(traits) == %{}
    # Except marks: nobody has one unless the run asks for it.
    assert Traits.sample_opts(%{}) == [marks: []]
    assert Traits.to_map(nil) == %{}
  end

  test "validates options and the age range" do
    assert {:error, changeset} =
             cast(%{
               "sex" => "other",
               "ancestry" => "Atlantean",
               "hair_style" => "mohawk",
               "age_min" => "17"
             })

    assert %{sex: _, ancestry: _, hair_style: _, age_min: _} = Map.new(changeset.errors)

    assert {:error, changeset} = cast(%{"age_min" => "50", "age_max" => "40"})
    assert {"must be at least the minimum age", _} = changeset.errors[:age_max]

    # An open end is the default one (18-75).
    assert {:error, _} = cast(%{"age_min" => "80"})
    assert {:ok, _} = cast(%{"age_min" => "80", "age_max" => "90"})
    assert {:ok, _} = cast(%{"age_max" => "30"})
  end

  test "every subject gets the fixed traits and a random rest" do
    stored =
      Traits.to_map(%Traits{
        sex: "female",
        ancestry: "Northern European",
        age_min: 30,
        age_max: 39,
        eye_color: "blue",
        hair_style: "ponytail",
        mark: "none"
      })

    people = for seed <- 1..40, do: sample(seed, stored)

    for person <- people do
      assert %{sex: :female, ancestry: "Northern European", eye_color: "blue", marks: []} =
               person

      assert person.age in 30..39
      assert person.hair =~ "ponytail"
      assert person.skin_tone in FaceAttributes.skin_tones("Northern European")
    end

    # What isn't fixed still varies.
    assert people |> Enum.map(& &1.age) |> Enum.uniq() |> length() > 3
    assert people |> Enum.map(& &1.clothing) |> Enum.uniq() |> length() > 3
    assert people |> Enum.map(& &1.hair_color) |> Enum.uniq() |> length() > 1
  end

  test "a fixed trait leaves the draws of the others alone" do
    for seed <- 1..40 do
      free = sample(seed, %{"mark" => "random"})

      fixed =
        sample(seed, %{
          "clothing" => "a burgundy sweatshirt",
          "build" => "slim",
          "mark" => "random"
        })

      assert %{clothing: "a burgundy sweatshirt", build: "slim"} = fixed
      assert Map.drop(fixed, [:clothing, :build]) == Map.drop(free, [:clothing, :build])
    end
  end

  test "distinguishing marks are the exception: none unless the run asks" do
    people = fn stored -> for seed <- 1..200, do: sample(seed, stored) end

    assert Enum.all?(people.(%{}), &(&1.marks == []))
    assert Enum.all?(people.(%{"mark" => "none"}), &(&1.marks == []))

    assert Enum.all?(
             people.(%{"mark" => "a slightly crooked nose"}),
             &(&1.marks == ["a slightly crooked nose"])
           )

    # Random: some get one, as FaceAttributes samples it on its own.
    with_marks = Enum.count(people.(%{"mark" => "random"}), &(&1.marks != []))
    assert with_marks in 40..100

    for seed <- 1..40,
        do: assert(sample(seed, %{"mark" => "random"}) == FaceAttributes.sample(seed))
  end

  test "facial hair only applies to men, and a fixed hair colour isn't greyed" do
    stored = %{"facial_hair" => "a goatee", "hair_color" => "red", "age_min" => 70}

    for seed <- 1..40 do
      person = sample(seed, stored)
      assert person.hair_color == "red"
      assert person.age >= 70

      if person.sex == :male,
        do: assert(person.facial_hair == "a goatee"),
        else: assert(person.facial_hair == nil)
    end
  end

  test "any hair style can be fixed for anyone" do
    for {_label, style} <- FaceAttributes.hair_styles(), seed <- [1, 2] do
      person = sample(seed, %{"hair_style" => style, "sex" => "female"})
      refute person.hair =~ "{"
    end

    assert sample(1, %{"hair_style" => "shaved"}).hair == "a shaved head"
  end

  test "describes the fixed traits" do
    assert Traits.describe(%{}) == []

    assert Traits.describe(%{
             "sex" => "male",
             "ancestry" => "East African",
             "age_min" => 40,
             "hair_style" => "buzz_cut",
             "mark" => "none"
           }) == ["Male", "East African", "40–75 years", "hair: buzz cut"]

    assert Traits.describe(%{"mark" => "random"}) == ["a mark on some"]

    assert Traits.describe(%{"age_min" => 30, "age_max" => 30}) == ["30 years"]
  end
end
