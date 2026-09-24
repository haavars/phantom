defmodule Phantom.Biometrics.ExportTest do
  use Phantom.DataCase, async: true

  import Phantom.BiometricsFixtures

  alias Phantom.Biometrics
  alias Phantom.Biometrics.{Export, Gallery, Storage}

  # One subject with faces, rolled and slap prints in two captures, palms and the card.
  setup do
    name =
      create_run(
        subjects: 1,
        shots: ["mugshot_left_profile", "rolled_02", "slaps", "palm_22", "card"],
        captures: 2
      )

    {:ok, export} = Biometrics.export_subject(name, "subject_001")
    %{name: name, export: export}
  end

  defp unzip(export) do
    zip = export |> Biometrics.export_stream() |> Enum.to_list() |> IO.iodata_to_binary()
    {:ok, files} = :zip.unzip(zip, [:memory])
    Map.new(files, fn {path, data} -> {List.to_string(path), data} end)
  end

  test "names files by shot, finger and capture, in one folder per person", %{export: export} do
    code = Gallery.code(export.subject.seed)
    assert export.folder == code
    assert export.filename == "#{code}_synthetic.zip"

    assert Enum.map(export.files, &Export.image_path/1) == [
             "face/mugshot_frontal_F.png",
             "face/mugshot_left_profile_L.png",
             "fingerprints/rolled/fgp02_R_index.png",
             "fingerprints/slaps/fgp13_Right_four.png",
             "fingerprints/slaps/fgp14_Left_four.png",
             "fingerprints/slaps/fgp15_Two_thumbs.png",
             "palms/plp22_R_writers_palm.png",
             "card/tenprint_card.png",
             "fingerprints/rolled/fgp02_R_index_c2.png",
             "fingerprints/slaps/fgp13_Right_four_c2.png",
             "fingerprints/slaps/fgp14_Left_four_c2.png",
             "fingerprints/slaps/fgp15_Two_thumbs_c2.png",
             "palms/plp22_R_writers_palm_c2.png",
             "card/tenprint_card_c2.png"
           ]

    assert export.missing == []
    assert Export.complete?(export)
  end

  test "the ZIP holds every image as stored, ground truth, a manifest and a README",
       %{export: export} do
    files = unzip(export)
    folder = export.folder

    for image <- export.files do
      assert files["#{folder}/#{Export.image_path(image)}"] == png()
    end

    assert %{"minutiae" => [_, _]} =
             Jason.decode!(files["#{folder}/ground_truth/fgp02_R_index.json"])

    refute Map.has_key?(files, "#{folder}/ground_truth/mugshot_frontal_F.json")

    readme = files["#{folder}/README.txt"]
    assert readme =~ "Synthetic test data. This person does not exist"
    assert readme =~ "fingerprints/"
    refute readme =~ "PARTIAL"

    manifest = Jason.decode!(files["#{folder}/subject.json"])

    assert %{"synthetic" => true, "complete" => true, "subject" => "subject_001", "missing" => []} =
             manifest

    assert manifest["code"] == folder
    assert length(manifest["files"]) == length(export.files)

    sha = :crypto.hash(:sha256, png()) |> Base.encode16(case: :lower)

    for file <- manifest["files"] do
      assert file["sha256"] == sha
      assert Map.has_key?(files, "#{folder}/#{file["path"]}")
    end

    rolled = Enum.find(manifest["files"], &(&1["shot"] == "rolled_02_c2"))

    assert %{
             "position" => "2",
             "capture" => 2,
             "ppi" => 500,
             "ground_truth" => "ground_truth/fgp02_R_index_c2.json"
           } = rolled

    profile = Enum.find(manifest["files"], &(&1["shot"] == "mugshot_left_profile"))
    assert %{"position" => "L", "reference" => "face/mugshot_frontal_F.png"} = profile
    assert profile["prompt"] =~ "left profile"
  end

  test "faces or prints only", %{name: name} do
    {:ok, faces} = Biometrics.export_subject(name, "subject_001", "faces")
    assert faces.filename =~ "_faces_synthetic.zip"
    assert Enum.all?(faces.files, &(&1.modality == :face))
    refute unzip(faces) |> Map.keys() |> Enum.any?(&(&1 =~ "ground_truth/"))

    {:ok, prints} = Biometrics.export_subject(name, "subject_001", "prints")
    assert length(prints.files) == 12
    assert Enum.all?(prints.files, &(&1.modality == :ridge))
    refute unzip(prints)["#{prints.folder}/README.txt"] =~ "face/"
  end

  test "lists shots that aren't in the download, and says it's partial", %{name: name} do
    {:ok, export} = Biometrics.export_subject(name, "subject_001")
    palm = Enum.find(export.files, &(&1.shot == "palm_22"))
    File.rm!(Path.join(Storage.Local.root(), palm.storage_key))

    {:ok, export} = Biometrics.export_subject(name, "subject_001")
    refute Enum.any?(export.files, &(&1.shot == "palm_22"))
    assert [%{shot: "palm_22", reason: "file_missing"}] = export.missing
    refute Export.complete?(export)

    files = unzip(export)
    assert files["#{export.folder}/README.txt"] =~ "PARTIAL"

    assert %{"complete" => false, "missing" => [%{"shot" => "palm_22"}]} =
             Jason.decode!(files["#{export.folder}/subject.json"])
  end

  test "summarises what each download holds", %{export: export} do
    summary = Export.summary(export.subject)
    size = byte_size(png())

    assert summary["all"] == %{files: 14, bytes: 14 * size}
    assert summary["faces"] == %{files: 2, bytes: 2 * size}
    assert summary["prints"] == %{files: 12, bytes: 12 * size}
  end

  test "names a single image after its person", %{export: export} do
    image = Enum.find(export.files, &(&1.shot == "rolled_02"))
    code = Gallery.code(export.subject.seed)
    assert Biometrics.download_name(image) == "#{code}_fgp02_R_index.png"
  end

  test "returns not_found for unknown subjects", %{name: name} do
    assert {:error, :not_found} = Biometrics.export_subject(name, "subject_999")
    assert {:error, :not_found} = Biometrics.export_subject("missing", "subject_001")
  end
end
