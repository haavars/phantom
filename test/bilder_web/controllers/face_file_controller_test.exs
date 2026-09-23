defmodule BilderWeb.FaceFileControllerTest do
  # Uses the global face output dir.
  use BilderWeb.ConnCase, async: false

  import Bilder.FaceFixtures

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    use_face_output_dir(root)
    {:ok, run: create_face_run(root)}
  end

  test "serves images from a run", %{conn: conn, run: run} do
    conn = get(conn, ~p"/face-files/#{run}/subject_001/mugshot_frontal.png")

    assert response(conn, 200) == png()
    assert response_content_type(conn, :png)
  end

  test "404s for missing files and unsafe names", %{conn: conn, run: run} do
    assert conn |> get(~p"/face-files/#{run}/subject_001/nope.png") |> response(404)
    assert conn |> get("/face-files/#{run}/subject_001/..") |> response(404)
    assert conn |> get("/face-files/#{run}/subject_001/run.txt") |> response(404)
  end
end
