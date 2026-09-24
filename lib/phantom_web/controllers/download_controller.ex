defmodule PhantomWeb.DownloadController do
  @moduledoc """
  Downloads of generated subjects as ZIP files (see
  `Phantom.Biometrics.Export`), streamed as they're built so large ones
  start at once and never sit in memory.
  """

  use PhantomWeb, :controller

  alias Phantom.Biometrics
  alias Phantom.Biometrics.Export

  @doc "`GET /biometrics/:run/:subject/download?include=all|faces|prints`"
  def subject(conn, %{"run" => run, "subject" => subject} = params) do
    include = if params["include"] in Export.includes(), do: params["include"], else: "all"

    case Biometrics.export_subject(run, subject, include) do
      {:ok, export} ->
        conn
        |> put_resp_content_type("application/zip", nil)
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{export.filename}"))
        |> put_resp_header("cache-control", "no-store")
        |> send_chunked(200)
        |> send_stream(Biometrics.export_stream(export))

      {:error, :not_found} ->
        send_resp(conn, 404, "Not found")
    end
  end

  # Stops early if the browser goes away, e.g. the download is cancelled.
  defp send_stream(conn, stream) do
    Enum.reduce_while(stream, conn, fn data, conn ->
      case chunk(conn, data) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end
end
