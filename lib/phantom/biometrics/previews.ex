defmodule Phantom.Biometrics.Previews do
  @moduledoc """
  Small WebP copies of images, for thumbnails.

  Full images are large: a full palm is 2750 × 4000 px at 500 ppi, about 9 MB
  as PNG, and friction ridges hardly compress without loss. A page of
  thumbnails would download tens of megabytes, so tiles show a preview that
  fits in 640 × 640 px instead, about 20–80 KB.

  Previews are made on first request and stored under
  `_previews/<sha256>.webp`, keyed by the image file's hash, so an image
  rendered again gets a new preview.
  """

  alias Phantom.Biometrics.{Image, Storage}
  alias Vix.Vips.Operation

  @size 640
  @format ".webp[Q=80]"

  @doc """
  The preview of `image` as WebP data, made and stored if it isn't yet.
  Returns `{:error, reason}` when the image has no file, or it can't be decoded.
  """
  def fetch(%Image{storage_key: key, sha256: sha}) when is_binary(key) and is_binary(sha) do
    preview_key = key(sha)

    case Storage.read(preview_key) do
      {:ok, webp} ->
        {:ok, webp}

      {:error, _} ->
        with {:ok, data} <- Storage.read(key),
             {:ok, webp} <- render(data) do
          # A preview that can't be stored is made again next time.
          Storage.put(preview_key, webp)
          {:ok, webp}
        end
    end
  end

  def fetch(_image), do: {:error, :no_file}

  @doc "Scales image data (PNG, JPEG) down to fit #{@size} × #{@size} px, as WebP."
  def render(data) do
    with {:ok, image} <-
           Operation.thumbnail_buffer(data, @size, height: @size, size: :VIPS_SIZE_DOWN) do
      Vix.Vips.Image.write_to_buffer(image, @format)
    end
  end

  @doc "The storage key of the preview of a file with hash `sha256`."
  def key(sha256), do: "_previews/#{sha256}.webp"
end
