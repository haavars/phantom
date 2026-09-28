defmodule Phantom.Biometrics.NistPartsTest do
  use ExUnit.Case, async: true

  alias Phantom.Biometrics.NistParts

  # A two-thumb slap as ridgegen draws it: the left thumb (finger 6) left of
  # the middle, the right thumb (1) right of it.
  @two_thumbs %{
    shot: "slap_15",
    width: 1600,
    height: 1500,
    ground_truth: %{
      "minutiae" => [
        %{"x" => 232, "y" => 161},
        %{"x" => 575, "y" => 1045},
        %{"x" => 1000, "y" => 221},
        %{"x" => 1397, "y" => 972}
      ]
    }
  }

  @full_palm %{
    shot: "palm_21",
    width: 2750,
    height: 4000,
    ground_truth: %{
      "triradii" => %{
        "a" => [848, 628],
        "b" => [1469, 670],
        "c" => [1973, 745],
        "d" => [2404, 989],
        "t" => [1280, 3487]
      }
    }
  }

  test "the ANSI/NIST target keeps every image whole" do
    assert NistParts.parts(@two_thumbs, "ansi_nist") == [{15, nil}]
    assert NistParts.parts(@full_palm, "ansi_nist") == [{21, nil}]
    assert NistParts.parts(%{shot: "rolled_02", width: 800, height: 750}, "unify") == [{2, nil}]
    assert NistParts.parts(%{shot: "palm_22", width: 875, height: 2500}, "unify") == [{22, nil}]
  end

  test "Unify: two thumbs become plain right and left thumbs, 500 × 1000 at most" do
    assert [{11, right}, {12, left}] = NistParts.parts(@two_thumbs, "unify")

    # Centred on each thumb's minutiae, from 100 px above the topmost.
    assert right == {948, 121, 500, 1000}
    assert left == {153, 61, 500, 1000}
  end

  test "Unify: a thumb stays inside its half, and without ground truth is the half" do
    near_edge = %{@two_thumbs | ground_truth: %{"minutiae" => [%{"x" => 1590, "y" => 1400}]}}

    assert [{11, {1100, 1300, 500, 200}}, {12, {150, 0, 500, 1000}}] =
             NistParts.parts(near_edge, "unify")

    small = %{shot: "slap_15", width: 800, height: 750, ground_truth: nil}
    assert NistParts.parts(small, "unify") == [{11, {400, 0, 400, 750}}, {12, {0, 0, 400, 750}}]
  end

  test "Unify: full palms become upper and lower palms, cut between the triradii" do
    # Halfway between d (989) and t (3487) is 2238; each runs 250 px past it.
    assert NistParts.parts(@full_palm, "unify") == [
             {26, {0, 0, 2750, 2488}},
             {25, {0, 1988, 2750, 2012}}
           ]

    left = %{@full_palm | shot: "palm_23"}
    assert [{28, _upper}, {27, _lower}] = NistParts.parts(left, "unify")
  end

  test "Unify: palm parts are at most 5.5 in tall, and cut in the middle without triradii" do
    no_truth = %{@full_palm | ground_truth: %{}}

    assert NistParts.parts(no_truth, "unify") == [
             {26, {0, 0, 2750, 2250}},
             {25, {0, 1750, 2750, 2250}}
           ]

    # Cut at 2745: the upper palm stops at 2750 px.
    low_cut = put_in(@full_palm.ground_truth["triradii"]["d"], [2404, 1500])
    low_cut = put_in(low_cut.ground_truth["triradii"]["t"], [1280, 3990])

    assert NistParts.parts(low_cut, "unify") == [
             {26, {0, 0, 2750, 2750}},
             {25, {0, 2495, 2750, 1505}}
           ]

    # Cut at 1244: the lower palm starts 2750 px above the bottom.
    high_cut = put_in(@full_palm.ground_truth["triradii"]["t"], [1280, 1500])

    assert NistParts.parts(high_cut, "unify") == [
             {26, {0, 0, 2750, 1494}},
             {25, {0, 1250, 2750, 2750}}
           ]
  end
end
