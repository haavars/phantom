defmodule PhantomWeb.ImageControllerTest do
  use PhantomWeb.ConnCase, async: true

  import Phantom.BiometricsFixtures

  alias Phantom.Biometrics

  defp image(run, shot) do
    {:ok, subject} = Biometrics.get_subject(run, "subject_001")
    Enum.find(subject.images, &(&1.shot == shot))
  end

  test "serves an image's file", %{conn: conn} do
    run = create_run()
    image = image(run, "mugshot_frontal")

    conn = get(conn, ~p"/images/#{image.id}")
    assert response(conn, 200) == png()
    assert response_content_type(conn, :png)
  end

  test "saves an image under its person's name with ?download=1", %{conn: conn} do
    run = create_run(subjects: 1, shots: ["rolled_02"])
    image = image(run, "rolled_02")
    {:ok, subject} = Biometrics.get_subject(run, "subject_001")
    code = Phantom.Biometrics.Gallery.code(subject.seed)

    assert conn |> get(~p"/images/#{image.id}") |> get_resp_header("content-disposition") == []

    conn = get(conn, ~p"/images/#{image.id}?download=1")
    assert response(conn, 200) == png()

    assert get_resp_header(conn, "content-disposition") ==
             [~s(attachment; filename="#{code}_fgp02_R_index.png")]
  end

  test "serves a friction-ridge image's ground truth", %{conn: conn} do
    run = create_run(subjects: 1, shots: ["rolled_03"])
    image = image(run, "rolled_03")

    assert %{"pattern" => "whorl", "minutiae" => [_, _]} =
             conn |> get(~p"/images/#{image.id}/ground-truth") |> json_response(200)
  end

  test "404s for missing images, files and ground truth", %{conn: conn} do
    run = create_run()
    face = image(run, "mugshot_frontal")

    assert conn |> get(~p"/images/0") |> response(404)
    assert conn |> get(~p"/images/#{Ecto.UUID.generate(version: 7)}") |> response(404)
    assert conn |> get("/images/not-an-id") |> response(404)
    assert conn |> get(~p"/images/#{face.id}/ground-truth") |> response(404)

    File.rm!(Path.join(Phantom.Biometrics.Storage.Local.root(), face.storage_key))
    assert conn |> get(~p"/images/#{face.id}") |> response(404)
  end
end
