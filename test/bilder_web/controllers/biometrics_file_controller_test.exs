defmodule BilderWeb.BiometricsFileControllerTest do
  # Uses the global face output dir.
  use BilderWeb.ConnCase, async: false

  import Bilder.BiometricsFixtures

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    use_output_dir(root)
    {:ok, run: create_run(root)}
  end

  test "serves images from a run", %{conn: conn, run: run} do
    conn = get(conn, ~p"/biometrics-files/#{run}/subject_001/mugshot_frontal.png")

    assert response(conn, 200) == png()
    assert response_content_type(conn, :png)
  end

  test "serves ground-truth JSON", %{conn: conn, tmp_dir: root} do
    run = create_run(root, run: "ridge-files", subjects: 1, shots: ["rolled_02"])
    conn = get(conn, ~p"/biometrics-files/#{run}/subject_001/rolled_02.json")

    assert %{"minutiae" => [_, _]} = json_response(conn, 200)
  end

  test "404s for missing files and unsafe names", %{conn: conn, run: run} do
    assert conn |> get(~p"/biometrics-files/#{run}/subject_001/nope.png") |> response(404)
    assert conn |> get("/biometrics-files/#{run}/subject_001/..") |> response(404)
    assert conn |> get("/biometrics-files/#{run}/subject_001/run.txt") |> response(404)
  end
end
