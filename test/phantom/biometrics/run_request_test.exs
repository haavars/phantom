defmodule Phantom.Biometrics.RunRequestTest do
  use ExUnit.Case, async: true

  alias Phantom.Biometrics.{FacePrompts, RunRequest}

  defp submit(params),
    do: params |> RunRequest.changeset() |> Ecto.Changeset.apply_action(:insert)

  test "defaults to face and friction-ridge shots and turns blank optional fields into nil" do
    assert {:ok, request} = submit(%{"subjects" => "2", "seed" => "", "run" => ""})
    assert request.shots == FacePrompts.default_shots() ++ ~w(rolled slaps palms card)

    assert RunRequest.to_opts(request) == [
             subjects: 2,
             steps: 40,
             shots: request.shots,
             captures: 1,
             renderer: "diffusion"
           ]
  end

  test "accepts friction-ridge groups and validates captures and empty selections" do
    assert {:ok, %{shots: ["rolled", "palms"], captures: 3}} =
             submit(%{"shots" => ["", "rolled", "palms"], "captures" => "3"})

    assert {:error, changeset} = submit(%{"shots" => [""], "captures" => "4"})
    assert %{shots: _, captures: _} = Map.new(changeset.errors)
  end

  test "drops the blank value the form sends with the shot checkboxes" do
    assert {:ok, request} = submit(%{"shots" => ["", "probe_aged"]})
    assert request.shots == ["probe_aged"]
  end

  test "validates ranges, steps, shots and run names" do
    assert {:error, changeset} =
             submit(%{
               "subjects" => "0",
               "steps" => "35",
               "shots" => ["selfie"],
               "renderer" => "crayon",
               "run" => "../escape"
             })

    errors = Map.new(changeset.errors, fn {field, _error} -> {field, true} end)
    assert %{subjects: true, steps: true, shots: true, renderer: true, run: true} = errors
  end
end
