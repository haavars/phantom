defmodule Phantom.Services.Qwen do
  @moduledoc """
  HTTP client for the local Qwen-Image-2.1 inference service
  (`python_inference/`), which renders images from text, optionally
  conditioned on reference images.

  It runs next to this app as `Phantom.Services.QwenProcess` (see
  `Phantom.Services.PythonProcess`).
  """

  @max_reference_images 10

  def max_reference_images, do: @max_reference_images

  @doc "Returns `:ready`, `:loading`, `{:error, reason}` or `:unreachable`."
  def health do
    case Req.get(request(), url: "/health") do
      {:ok, %Req.Response{body: %{"status" => "ready"}}} -> :ready
      {:ok, %Req.Response{body: %{"status" => "loading"}}} -> :loading
      {:ok, %Req.Response{body: %{"status" => "error", "error" => reason}}} -> {:error, reason}
      {:ok, %Req.Response{status: status}} -> {:error, "unexpected response (HTTP #{status})"}
      {:error, _exception} -> :unreachable
    end
  end

  @doc """
  Renders an image for `prompt`. Options:

    * `:width` and `:height` - output size in pixels (multiples of 32), required
    * `:steps` - number of denoising steps, defaults to 40
    * `:seed` - integer seed for reproducibility, defaults to a random seed
      chosen by the service
    * `:images` - up to #{@max_reference_images} reference images to generate
      from, each a map with `:data` (binary), `:filename` and `:content_type`

  Returns `{:ok, %{image: png, seed: seed}}` (the seed the service used, as a
  string, or `nil`) or `{:error, message}`.
  """
  def render(prompt, opts)

  def render("", _opts), do: {:error, "Prompt can't be blank."}

  def render(prompt, opts) when is_binary(prompt) do
    images = Keyword.get(opts, :images, [])

    if length(images) > @max_reference_images do
      {:error, "You can attach at most #{@max_reference_images} reference images."}
    else
      post_generate(prompt, opts, images)
    end
  end

  defp post_generate(prompt, opts, images) do
    fields =
      [
        {"prompt", prompt},
        {"width", Keyword.fetch!(opts, :width)},
        {"height", Keyword.fetch!(opts, :height)},
        {"steps", Keyword.get(opts, :steps, 40)}
      ] ++ seed_field(Keyword.get(opts, :seed)) ++ Enum.map(images, &image_field/1)

    case Req.post(request(), url: "/generate", form_multipart: fields) do
      {:ok, %Req.Response{status: 200, body: png, headers: headers}} ->
        {:ok, %{image: png, seed: headers |> Map.get("x-seed", []) |> List.first()}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "Generation failed (HTTP #{status}): #{inspect(body)}"}

      {:error, %{reason: :econnrefused}} ->
        {:error,
         "Couldn't reach the Qwen-Image-2.1 service at #{base_url()}. " <>
           "Make sure `python_inference/server.py` is running."}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp seed_field(nil), do: []
  defp seed_field(seed), do: [{"seed", seed}]

  defp image_field(%{data: data, filename: filename, content_type: content_type}),
    do: {"images", {data, filename: filename, content_type: content_type}}

  defp request do
    extra_opts = Application.get_env(:phantom, :qwen_image_req_options, [])
    # A local, single-instance service: don't retry with backoff on connection
    # errors, just report it as unreachable right away.
    Req.new(
      [base_url: base_url(), receive_timeout: :timer.minutes(10), retry: false] ++ extra_opts
    )
  end

  defp base_url, do: Application.fetch_env!(:phantom, :qwen_service_url)
end
