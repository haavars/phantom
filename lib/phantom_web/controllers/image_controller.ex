defmodule PhantomWeb.ImageController do
  @moduledoc """
  Serves a generated image's file and its ground truth, by image id. Files
  live in `Phantom.Biometrics.Storage`, outside `priv/static`.
  """

  use PhantomWeb, :controller

  alias Phantom.Biometrics.{Runs, Storage}

  def show(conn, %{"id" => id}) do
    with {:ok, image} <- fetch_image(id),
         key when is_binary(key) <- image.storage_key,
         {:ok, path} <- Storage.local_path(key) do
      conn
      |> put_resp_content_type(image.content_type || "image/png", nil)
      # Images can be rendered again in place with --force, so don't cache for long.
      |> put_resp_header("cache-control", "private, max-age=60")
      |> send_file(200, path)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  def ground_truth(conn, %{"id" => id}) do
    case fetch_image(id) do
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

  defp fetch_image(id) do
    case Integer.parse(id) do
      {id, ""} -> Runs.get_image(id)
      _ -> {:error, :not_found}
    end
  end
end
