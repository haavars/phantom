defmodule Phantom.Biometrics.NistImages do
  @moduledoc """
  Image data for NIST records (`Phantom.Biometrics.NistExport`), from the
  PNGs Phantom stores.

    * Prints and palms are 8-bit grey PNG at 500 ppi. As `"png"` they go in
      byte for byte (CGA `PNG`); as `"wsq"` they're compressed with NIST's
      `cwsq` at 0.75 bits per pixel, about 15:1 (CGA `WSQ20`).
    * Faces go in as PNG in either case: Type-10 doesn't allow WSQ. Faces
      with an alpha channel (the face model's output is RGBA) are flattened
      onto white first, since Type-10 has no colour space with alpha.

  `cwsq` is built by `python_biometrics/setup.sh` into
  `python_biometrics/tools/nbis/bin`; `NBIS_BIN` points elsewhere, as for
  the friction-ridge service.
  """

  alias Vix.Vips.{Image, Operation}

  @wsq_bitrate "0.75"

  @doc "True when `cwsq` is installed, so prints can be exported as WSQ."
  def wsq_available?, do: File.exists?(tool("cwsq"))

  @doc """
  A print or palm as `%{data:, width:, height:, ppi:, cga:}`, from its stored
  PNG. `compression` is `"png"` or `"wsq"`.
  """
  def print(png, %{width: width, height: height}, ppi, "png") do
    {:ok, %{data: png, width: width, height: height, ppi: ppi, cga: "PNG"}}
  end

  def print(png, _image, ppi, "wsq") do
    with {:ok, image} <- decode(png),
         {:ok, grey} <- grey(image),
         {:ok, raw} <- Image.write_to_binary(grey),
         {:ok, wsq} <- cwsq(raw, Image.width(grey), Image.height(grey), ppi) do
      {:ok,
       %{data: wsq, width: Image.width(grey), height: Image.height(grey), ppi: ppi, cga: "WSQ20"}}
    end
  end

  @doc """
  A face as `%{data:, width:, height:, cga:, csp:}`: the stored PNG as it is
  when it has no alpha, otherwise flattened onto white and re-encoded.
  """
  def face(png, %{width: width, height: height}) do
    case png_color_type(png) do
      type when type in [0, 2] ->
        {:ok, face_data(png, width, height, type)}

      type when type in [3, 4, 6] ->
        flatten(png)

      # Not a PNG header we can read: pass it through as colour.
      nil ->
        {:ok, face_data(png, width, height, 2)}
    end
  end

  defp face_data(png, width, height, type) do
    %{
      data: png,
      width: width,
      height: height,
      cga: "PNG",
      csp: if(type == 0, do: "GRAY", else: "SRGB")
    }
  end

  # The colour type in a PNG's IHDR chunk: 0 grey, 2 RGB, 3 palette,
  # 4 grey + alpha, 6 RGBA.
  defp png_color_type(
         <<137, 80, 78, 71, 13, 10, 26, 10, _length::32, "IHDR", _width::32, _height::32, _depth,
           type, _rest::binary>>
       ),
       do: type

  defp png_color_type(_data), do: nil

  defp flatten(png) do
    with {:ok, image} <- decode(png),
         {:ok, image} <- srgb(image),
         {:ok, flat} <- Operation.flatten(image, background: [255.0, 255.0, 255.0]),
         {:ok, data} <- Image.write_to_buffer(flat, ".png") do
      {:ok, face_data(data, Image.width(flat), Image.height(flat), 2)}
    end
  end

  defp decode(data) do
    case Image.new_from_buffer(data) do
      {:ok, image} -> {:ok, image}
      {:error, _reason} -> {:error, :undecodable_image}
    end
  end

  defp srgb(image) do
    if Image.bands(image) in [3, 4],
      do: {:ok, image},
      else: Operation.colourspace(image, :VIPS_INTERPRETATION_sRGB)
  end

  # One 8-bit band: stored prints already are; anything else is flattened
  # and converted.
  defp grey(image) do
    with {:ok, image} <- flatten_alpha(image),
         {:ok, image} <- one_band(image) do
      Operation.cast(image, :VIPS_FORMAT_UCHAR)
    end
  end

  defp flatten_alpha(image) do
    if Image.has_alpha?(image),
      do: Operation.flatten(image, background: [255.0]),
      else: {:ok, image}
  end

  defp one_band(image) do
    if Image.bands(image) == 1,
      do: {:ok, image},
      else: Operation.colourspace(image, :VIPS_INTERPRETATION_B_W)
  end

  defp cwsq(raw, width, height, ppi) do
    if wsq_available?() do
      dir = Path.join(System.tmp_dir!(), "phantom-wsq-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      try do
        input = Path.join(dir, "print.raw")
        File.write!(input, raw)

        args = [@wsq_bitrate, "wsq", input, "-raw_in", "#{width},#{height},8,#{ppi}"]

        case System.cmd(tool("cwsq"), args, stderr_to_stdout: true) do
          {_out, 0} -> File.read(Path.join(dir, "print.wsq"))
          {out, status} -> {:error, {:cwsq, status, String.trim(out)}}
        end
      after
        File.rm_rf(dir)
      end
    else
      {:error, :wsq_unavailable}
    end
  end

  @doc "The path of an NBIS tool (`cwsq`, `dwsq`, `an2ktool`)."
  def tool(name) do
    dir =
      System.get_env("NBIS_BIN") ||
        Path.join(Application.fetch_env!(:phantom, :biometrics_service_dir), "tools/nbis/bin")

    Path.join(dir, name)
  end
end
