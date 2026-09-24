defmodule Phantom.ImageGeneration do
  @moduledoc """
  Generates images by calling the local Qwen-Image-2.1 inference service
  (see `python_inference/`) over HTTP and saving the result to
  `priv/static/uploads`.
  """

  alias Phantom.ImageGeneration.Result

  @uploads_dir Path.join([:code.priv_dir(:phantom), "static", "uploads"])

  @aspect_ratios %{
    "1:1" => {1024, 1024},
    "16:9" => {1360, 768},
    "9:16" => {768, 1360},
    "4:3" => {1152, 864},
    "3:4" => {864, 1152},
    "3:2" => {1248, 832},
    "2:3" => {832, 1248}
  }

  @max_reference_images 10

  def aspect_ratios, do: Map.keys(@aspect_ratios)
  def max_reference_images, do: @max_reference_images

  @doc """
  Checks readiness of the Qwen-Image-2.1 service.

  Returns `:ready`, `:loading`, `{:error, reason}`, or `:unreachable`.
  """
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
  Generates an image for `prompt` and saves it under `priv/static/uploads`.

  Takes the same options as `render/2`.

  Returns `{:ok, %Phantom.ImageGeneration.Result{}}` or `{:error, message}`.
  """
  def generate(prompt, opts \\ []) do
    with {:ok, %{image: image, seed: seed}} <- render(prompt, opts) do
      save_image(image, prompt, seed)
    end
  end

  @doc """
  Renders an image for `prompt` and returns the PNG without saving it.

  Options:

    * `:aspect_ratio` - one of #{inspect(Map.keys(@aspect_ratios))}, defaults to "1:1"
    * `:width` / `:height` - explicit output size in pixels (use multiples of 32),
      overriding `:aspect_ratio`
    * `:steps` - number of denoising steps, defaults to 40
    * `:seed` - integer seed for reproducibility, defaults to a random seed
      chosen by the inference service
    * `:images` - up to #{@max_reference_images} reference images to generate from/with (for
      image-conditioned generation and editing). Each is a map with `:data` (binary),
      `:filename`, and `:content_type`.

  Returns `{:ok, %{image: png_binary, seed: seed}}` (the seed the service actually
  used, as a string, or `nil`) or `{:error, message}`.
  """
  def render(prompt, opts \\ [])

  def render(prompt, _opts) when is_binary(prompt) and byte_size(prompt) == 0 do
    {:error, "Prompt can't be blank."}
  end

  def render(prompt, opts) when is_binary(prompt) do
    images = Keyword.get(opts, :images, [])

    if length(images) > @max_reference_images do
      {:error, "You can attach at most #{@max_reference_images} reference images."}
    else
      do_render(prompt, opts, images)
    end
  end

  defp do_render(prompt, opts, images) do
    {width, height} = dimensions(opts)

    fields =
      [
        {"prompt", prompt},
        {"width", width},
        {"height", height},
        {"steps", Keyword.get(opts, :steps, 40)}
      ] ++
        seed_field(Keyword.get(opts, :seed)) ++
        image_fields(images)

    case Req.post(request(), url: "/generate", form_multipart: fields) do
      {:ok, %Req.Response{status: 200, body: image_binary, headers: headers}} ->
        seed =
          headers
          |> Map.get("x-seed", [])
          |> List.first()

        {:ok, %{image: image_binary, seed: seed}}

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

  defp dimensions(opts) do
    case {Keyword.get(opts, :width), Keyword.get(opts, :height)} do
      {width, height} when is_integer(width) and is_integer(height) -> {width, height}
      _ -> Map.get(@aspect_ratios, Keyword.get(opts, :aspect_ratio, "1:1"))
    end
  end

  defp seed_field(nil), do: []
  defp seed_field(seed), do: [{"seed", seed}]

  defp image_fields(images) do
    Enum.map(images, fn %{data: data, filename: filename, content_type: content_type} ->
      {"images", {data, filename: filename, content_type: content_type}}
    end)
  end

  defp request do
    extra_opts = Application.get_env(:phantom, :qwen_image_req_options, [])
    # This is a local, single-instance service: don't retry with backoff on
    # connection errors, just surface "unreachable" immediately.
    Req.new(
      [base_url: base_url(), receive_timeout: :timer.minutes(10), retry: false] ++ extra_opts
    )
  end

  defp base_url, do: Application.fetch_env!(:phantom, :qwen_service_url)

  defp save_image(image_binary, prompt, seed) do
    File.mkdir_p!(@uploads_dir)

    filename =
      "#{System.system_time(:millisecond)}-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}.png"

    File.write!(Path.join(@uploads_dir, filename), image_binary)

    {:ok, %Result{path: "/uploads/#{filename}", prompt: prompt, seed: seed}}
  end
end
