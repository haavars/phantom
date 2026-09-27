defmodule Phantom.Biometrics.FaceGateTest do
  use ExUnit.Case, async: true

  import Phantom.BiometricsFixtures, only: [stub_ridge: 1, face_template: 1, face_template: 3]

  alias Phantom.Biometrics.FaceGate

  # The embedder returns `responses` in order, one per call.
  defp stub_embeddings(responses) do
    agent = start_supervised!({Agent, fn -> responses end})
    stub_ridge(embed: fn -> Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end) end)
  end

  defp face(template), do: %{faces: 1, det: 0.9, template: template}

  # Renders attempt n as "png-n" and reports it to the test process.
  defp render do
    test_pid = self()

    fn n ->
      send(test_pid, {:rendered, n})
      {:ok, "png-#{n}", %{attempt: n}}
    end
  end

  defp others, do: [{"subject_001", Base.decode64!(face_template(0))}]

  test "keeps the first attempt that isn't like anyone else" do
    stub_embeddings([face(face_template(1))])

    assert {:ok, "png-0", %{attempt: 0}, template, gate} = FaceGate.run(others(), render())
    assert template == Base.decode64!(face_template(1))

    assert gate == %{
             "faces" => 1,
             "similarity" => 0.0,
             "closest" => "subject_001",
             "threshold" => 0.35,
             "passed" => true,
             "attempts" => 1,
             "attempt" => 0,
             "scores" => [0.0]
           }

    assert_received {:rendered, 0}
    refute_received {:rendered, 1}
  end

  test "renders again until an attempt passes" do
    stub_embeddings([
      face(face_template(1, 0, 0.6)),
      face(face_template(2, 0, 0.4)),
      face(face_template(3, 0, 0.2))
    ])

    assert {:ok, "png-2", _extra, _template, gate} = FaceGate.run(others(), render())
    assert %{"passed" => true, "attempts" => 3, "attempt" => 2} = gate
    assert gate["scores"] == [0.6, 0.4, 0.2]
    assert gate["similarity"] == 0.2
  end

  test "keeps the attempt least like anyone when none passes, and a face over no face" do
    stub_embeddings([
      %{faces: 0},
      face(face_template(1, 0, 0.5)),
      face(face_template(2, 0, 0.4)),
      face(face_template(3, 0, 0.45)),
      face(face_template(4, 0, 0.9))
    ])

    assert {:ok, "png-2", _extra, _template, gate} = FaceGate.run(others(), render())
    assert %{"passed" => false, "attempts" => 5, "attempt" => 2, "similarity" => 0.4} = gate
    assert gate["scores"] == [nil, 0.5, 0.4, 0.45, 0.9]
  end

  test "passes the first anchor of a run, with nobody to compare it with" do
    stub_embeddings([face(face_template(0))])

    assert {:ok, "png-0", _extra, _template, gate} = FaceGate.run([], render())
    assert %{"passed" => true, "similarity" => nil, "closest" => nil} = gate
  end

  test "an image without a face fails the check" do
    stub_embeddings([%{faces: 0}])

    assert {:ok, nil, %{"faces" => 0, "passed" => false}} = FaceGate.check("png", others())
  end

  test "keeps the first attempt unchecked when the service fails" do
    stub_ridge(embed: fn -> {500, %{detail: "boom"}} end)

    assert {:ok, "png-0", _extra, nil, %{"error" => message}} =
             FaceGate.run(others(), render(), 5)

    assert message =~ "Face embedding failed"
    refute_received {:rendered, 1}
  end

  test "stops at the first render error" do
    stub_embeddings([face(face_template(0))])

    render = fn
      0 -> {:ok, "png-0", %{}}
      _n -> {:error, "render failed"}
    end

    assert FaceGate.run(others(), render) == {:error, "render failed"}
  end

  test "similarity is the dot product of two templates" do
    a = Base.decode64!(face_template(0))
    b = Base.decode64!(face_template(1, 0, 0.3))

    assert FaceGate.similarity(a, b) == 0.3
    assert FaceGate.similarity(a, a) == 1.0
    assert FaceGate.nearest(b, [{"x", a}, {"y", b}]) == {"y", 1.0}
    assert FaceGate.nearest(b, []) == {nil, nil}
  end
end
