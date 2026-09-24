defmodule PhantomWeb.DownloadControllerTest do
  use PhantomWeb.ConnCase, async: true

  import Phantom.BiometricsFixtures

  alias Phantom.Biometrics.Gallery

  defp unzip(body) do
    {:ok, files} = :zip.unzip(body, [:memory])
    files |> Enum.map(fn {path, _data} -> List.to_string(path) end) |> Enum.sort()
  end

  test "streams one person as a ZIP", %{conn: conn} do
    run = create_run(subjects: 1, shots: ["mugshot_left_profile", "rolled_02"])
    {:ok, subject} = Phantom.Biometrics.get_subject(run, "subject_001")
    code = Gallery.code(subject.seed)

    conn = get(conn, ~p"/biometrics/#{run}/subject_001/download")

    assert conn.status == 200
    assert conn.state == :chunked
    assert get_resp_header(conn, "content-type") == ["application/zip"]

    assert get_resp_header(conn, "content-disposition") ==
             [~s(attachment; filename="#{code}_synthetic.zip")]

    assert unzip(conn.resp_body) == [
             "#{code}/README.txt",
             "#{code}/face/mugshot_frontal_F.png",
             "#{code}/face/mugshot_left_profile_L.png",
             "#{code}/fingerprints/rolled/fgp02_R_index.png",
             "#{code}/ground_truth/fgp02_R_index.json",
             "#{code}/subject.json"
           ]
  end

  test "takes faces or prints only, and treats anything else as everything", %{conn: conn} do
    run = create_run(subjects: 1, shots: ["mugshot_left_profile", "rolled_02"])

    faces = get(conn, ~p"/biometrics/#{run}/subject_001/download?include=faces")
    assert [_] = get_resp_header(faces, "content-disposition")
    refute faces.resp_body |> unzip() |> Enum.any?(&(&1 =~ "fingerprints/"))

    prints = get(conn, ~p"/biometrics/#{run}/subject_001/download?include=prints")
    refute prints.resp_body |> unzip() |> Enum.any?(&(&1 =~ "face/"))

    other = get(conn, ~p"/biometrics/#{run}/subject_001/download?include=secrets")
    assert other.resp_body |> unzip() |> length() == 6
  end

  test "404s for unknown runs and subjects", %{conn: conn} do
    run = create_run(subjects: 1)

    assert conn |> get(~p"/biometrics/#{run}/subject_999/download") |> response(404)
    assert conn |> get(~p"/biometrics/missing/subject_001/download") |> response(404)
  end
end
