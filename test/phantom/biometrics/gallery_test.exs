defmodule Phantom.Biometrics.GalleryTest do
  use Phantom.DataCase, async: true

  import Phantom.BiometricsFixtures

  alias Phantom.Biometrics.Gallery

  test "builds identities with portraits, prints and counts" do
    faces = create_run(subjects: 2)
    ridges = create_run(subjects: 1, shots: ["rolled", "card"])

    identities = Enum.filter(Gallery.identities(), &(&1.run in [faces, ridges]))
    assert length(identities) == 3

    face = Enum.find(identities, &(&1.run == faces))
    assert %{shot: "mugshot_frontal"} = face.portrait
    assert face.prints == []
    assert face.counts == %{"face" => 2}
    assert face.code =~ ~r/\APH-[0-9A-F]{4}-[0-9A-F]{4}\z/
    assert face.sex in ["female", "male"]

    ridge = Enum.find(identities, &(&1.run == ridges))
    assert ridge.portrait == nil
    assert Enum.map(ridge.prints, & &1.fgp) == Enum.to_list(1..10)
    assert Enum.all?(ridge.prints, &(&1.pattern == "whorl"))
    assert ridge.counts == %{"rolled" => 10, "card" => 1}

    assert %{identities: 3, faces: 2, prints: 1, runs: 2, images: 15} = Gallery.stats(identities)
  end

  test "limits the number of identities" do
    create_run(subjects: 2)

    assert [_one] = Gallery.identities(1)
  end

  test "leaves out subjects without rendered images" do
    Req.Test.stub(Phantom.ImageGeneration, &Plug.Conn.send_resp(&1, 500, "boom"))
    {:ok, %{run: run}} = Phantom.Biometrics.Harness.run(run: unique_run_name(), subjects: 1)

    refute Enum.any?(Gallery.identities(), &(&1.run == run.name))
  end
end
