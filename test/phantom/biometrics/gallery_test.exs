defmodule Phantom.Biometrics.GalleryTest do
  use ExUnit.Case, async: true

  import Phantom.BiometricsFixtures

  alias Phantom.Biometrics.Gallery

  @moduletag :tmp_dir

  test "builds identities with portraits, prints and counts", %{tmp_dir: root} do
    create_run(root, run: "faces", subjects: 2)
    create_run(root, run: "ridges", subjects: 1, shots: ["rolled", "card"])

    identities = Gallery.identities(48, root)
    assert length(identities) == 3

    face = Enum.find(identities, &(&1.run == "faces"))
    assert face.portrait == "mugshot_frontal.png"
    assert face.prints == []
    assert face.counts == %{"face" => 2}
    assert face.code =~ ~r/\APH-[0-9A-F]{4}-[0-9A-F]{4}\z/
    assert face.sex in ["female", "male"]

    ridge = Enum.find(identities, &(&1.run == "ridges"))
    assert ridge.portrait == nil
    assert Enum.map(ridge.prints, & &1.fgp) == Enum.to_list(1..10)
    assert Enum.all?(ridge.prints, &(&1.pattern == "whorl"))
    assert ridge.counts == %{"rolled" => 10, "card" => 1}

    assert %{identities: 3, faces: 2, prints: 1, runs: 2, images: 15} = Gallery.stats(identities)
  end

  test "limits and handles a missing output folder", %{tmp_dir: root} do
    create_run(root, subjects: 2)

    assert [_one] = Gallery.identities(1, root)
    assert Gallery.identities(48, Path.join(root, "missing")) == []
  end
end
