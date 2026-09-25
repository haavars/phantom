defmodule PhantomWeb.ImageControllerTest do
  use PhantomWeb.ConnCase, async: true

  import Phantom.BiometricsFixtures

  alias Phantom.Biometrics
  alias Phantom.Biometrics.{Previews, Storage}

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

  describe "preview" do
    # A real 1200 × 900 PNG in place of the fixture's fake one.
    defp store_real_png(image) do
      {:ok, black} = Vix.Vips.Operation.black(1200, 900)
      {:ok, png} = Vix.Vips.Image.write_to_buffer(black, ".png")
      {:ok, stored} = Storage.put(image.storage_key, png)
      image |> Ecto.Changeset.change(sha256: stored.sha256) |> Phantom.Repo.update!()
    end

    test "serves a small WebP copy and keeps it", %{conn: conn} do
      run = create_run(subjects: 1, shots: ["slap_13"])
      image = run |> image("slap_13") |> store_real_png()

      conn = get(conn, ~p"/images/#{image.id}/preview")
      assert response_content_type(conn, :webp)
      {:ok, preview} = Vix.Vips.Image.new_from_buffer(response(conn, 200))
      assert {Vix.Vips.Image.width(preview), Vix.Vips.Image.height(preview)} == {640, 480}
      assert Storage.exists?(Previews.key(image.sha256))

      # Served from storage once made.
      File.rm!(Path.join(Storage.Local.root(), image.storage_key))

      assert build_conn() |> get(~p"/images/#{image.id}/preview") |> response(200) ==
               response(conn, 200)
    end

    test "falls back to the image's file when it can't be decoded, and 404s without one", %{
      conn: conn
    } do
      run = create_run()
      face = image(run, "mugshot_frontal")

      conn = get(conn, ~p"/images/#{face.id}/preview")
      assert response(conn, 200) == png()
      assert response_content_type(conn, :png)

      File.rm!(Path.join(Storage.Local.root(), face.storage_key))
      assert build_conn() |> get(~p"/images/#{face.id}/preview") |> response(404)

      assert build_conn()
             |> get(~p"/images/#{Ecto.UUID.generate(version: 7)}/preview")
             |> response(404)
    end
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
