defmodule PhantomWeb.ImageController do
  @moduledoc """
  Serves a generated image's file (`?download=1` to save it), a small preview
  of it for thumbnails, and its ground truth, by image id (a UUIDv7). Files live in storage (`Phantom.Biometrics.Storage`),
  outside `priv/static`.
  """

  use PhantomWeb, :controller

  alias Phantom.Biometrics

  def show(conn, %{"id" => id} = params) do
    with {:ok, image} <- Biometrics.get_image(id),
         {:ok, path} <- Biometrics.image_path(image) do
      conn
      |> put_resp_content_type(image.content_type || "image/png", nil)
      # Images can be rendered again in place, so don't cache for long.
      |> put_resp_header("cache-control", "private, max-age=60")
      |> attachment(params["download"] in ["1", "true"], image)
      |> send_file(200, path)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  @doc """
  Serves a small WebP copy of an image, for thumbnails. Falls back to the
  image's own file when no preview can be made from it.
  """
  def preview(conn, %{"id" => id}) do
    with {:ok, image} <- Biometrics.get_image(id),
         {:ok, webp} <- Biometrics.image_preview(image) do
      conn
      |> put_resp_content_type("image/webp", nil)
      |> put_resp_header("cache-control", "private, max-age=60")
      |> send_resp(200, webp)
    else
      _ -> show(conn, %{"id" => id})
    end
  end

  # `?download=1` saves the image under a name that says whose it is.
  defp attachment(conn, false, _image), do: conn

  defp attachment(conn, true, image) do
    put_resp_header(
      conn,
      "content-disposition",
      ~s(attachment; filename="#{Biometrics.download_name(image)}")
    )
  end

  def ground_truth(conn, %{"id" => id}) do
    case Biometrics.get_image(id) do
      {:ok, %{ground_truth: %{} = truth} = image} ->
        conn
        |> put_resp_header(
          "content-disposition",
          ~s(inline; filename="#{image.shot}.json")
        )
        |> json(truth)

      _ ->
        send_resp(conn, 404, "Not found")
    end
  end
end
