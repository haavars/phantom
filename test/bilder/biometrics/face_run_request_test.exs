defmodule Bilder.Biometrics.FaceRunRequestTest do
  use ExUnit.Case, async: true

  alias Bilder.Biometrics.{FacePrompts, FaceRunRequest}

  defp submit(params),
    do: params |> FaceRunRequest.changeset() |> Ecto.Changeset.apply_action(:insert)

  test "defaults to the default shots and turns blank optional fields into nil" do
    assert {:ok, request} = submit(%{"subjects" => "2", "seed" => "", "run" => ""})
    assert request.shots == FacePrompts.default_shots()

    assert FaceRunRequest.to_opts(request) == [
             subjects: 2,
             steps: 40,
             shots: FacePrompts.default_shots()
           ]
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
               "run" => "../escape"
             })

    errors = Map.new(changeset.errors, fn {field, _error} -> {field, true} end)
    assert %{subjects: true, steps: true, shots: true, run: true} = errors
  end
end
