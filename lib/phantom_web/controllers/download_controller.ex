defmodule PhantomWeb.DownloadController do
  @moduledoc """
  Downloads of generated subjects, as ZIP files (see
  `Phantom.Biometrics.Export`) or ANSI/NIST-ITL transactions (see
  `Phantom.Biometrics.NistExport`), streamed as they're built so large ones
  start at once and never sit in memory.
  """

  use PhantomWeb, :controller

  alias Phantom.Biometrics
  alias Phantom.Biometrics.{Export, NistExport}

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

  @doc """
  `GET /biometrics/:run/:subject/nist/download?content=&compression=&search[]=`:
  the subject as ANSI/NIST-ITL transactions, one `.an2` file, or a ZIP when
  there are search transactions too.
  """
  def nist(conn, %{"run" => run, "subject" => subject} = params) do
    opts = Map.take(params, ["content", "compression", "search"])

    case Biometrics.nist_export(run, subject, opts) do
      {:ok, export} ->
        conn
        |> put_resp_content_type(NistExport.content_type(export), nil)
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="#{NistExport.filename(export)}")
        )
        |> put_resp_header("cache-control", "no-store")
        |> send_chunked(200)
        |> send_stream(NistExport.stream(export))

      {:error, :not_found} ->
        send_resp(conn, 404, "Not found")

      {:error, :empty} ->
        send_resp(conn, 404, "Nothing to export: this person has no images of that kind yet.")

      {:error, :wsq_unavailable} ->
        send_resp(conn, 422, "WSQ needs NIST's cwsq: run python_biometrics/setup.sh, or use PNG.")
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
