defmodule Phantom.ImageGeneration do
  @moduledoc """
  Plain text-to-image generation for `PhantomWeb.GenerateLive`: renders with
  `Phantom.Services.Qwen` at a chosen aspect ratio and saves the result to
  `priv/static/uploads`.
  """

  alias Phantom.ImageGeneration.Result
  alias Phantom.Services.Qwen

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

  def aspect_ratios, do: Map.keys(@aspect_ratios)
  defdelegate max_reference_images, to: Qwen
  defdelegate health, to: Qwen

  @doc """
  Generates an image for `prompt` and saves it under `priv/static/uploads`.
  Options are those of `Phantom.Services.Qwen.render/2`, with
  `:aspect_ratio` (one of `aspect_ratios/0`, default "1:1") instead of the size.

  Returns `{:ok, %Phantom.ImageGeneration.Result{}}` or `{:error, message}`.
  """
  def generate(prompt, opts \\ []) do
    {width, height} = Map.fetch!(@aspect_ratios, Keyword.get(opts, :aspect_ratio, "1:1"))
    opts = Keyword.merge(opts, width: width, height: height)

    with {:ok, %{image: image, seed: seed}} <- Qwen.render(prompt, opts) do
      save_image(image, prompt, seed)
    end
  end

  defp save_image(image, prompt, seed) do
    File.mkdir_p!(@uploads_dir)
    suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    filename = "#{System.system_time(:millisecond)}-#{suffix}.png"
    File.write!(Path.join(@uploads_dir, filename), image)

    {:ok, %Result{path: "/uploads/#{filename}", prompt: prompt, seed: seed}}
  end
end
