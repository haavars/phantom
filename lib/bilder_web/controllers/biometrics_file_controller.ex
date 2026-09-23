defmodule BilderWeb.BiometricsFileController do
  @moduledoc """
  Serves images and JSON from face-harness runs, which live outside
  `priv/static` (see `Bilder.Biometrics.Runs.root/0`).
  """

  use BilderWeb, :controller

  alias Bilder.Biometrics.Runs

  def show(conn, %{"run" => run, "subject" => subject, "file" => file}) do
    case Runs.file_path(run, subject, file) do
      {:ok, path} ->
        conn
        |> put_resp_content_type(MIME.from_path(path), nil)
        # Images can be regenerated in place with --force, so don't cache for long.
        |> put_resp_header("cache-control", "private, max-age=60")
        |> send_file(200, path)

      {:error, :not_found} ->
        send_resp(conn, 404, "Not found")
    end
  end
end
