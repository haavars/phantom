defmodule PhantomWeb.ImageController do
  @moduledoc """
  Serves a generated image's file (`?download=1` to save it) and its ground
  truth, by image id (a UUIDv7). Files live in storage (`Phantom.Biometrics.Storage`),
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
