defmodule Phantom.Nist.Type10 do
  @moduledoc """
  A Type-10 facial image record (IMT `FACE`), with the mandatory fields of
  NIST SP 500-290 Ed. 3, Section 8.10, and the subject pose.

  Faces have no physical scale, so 10.008 SLC is 0 and THPS/TVPS give the
  pixel aspect ratio, 1:1. 10.013 SAP is mandatory for faces (Table 12). The
  subject acquisition profiles from 30 up constrain composition and
  compression (Annex E); `Phantom.Biometrics.NistExport` only claims 0
  (unknown) and 20 (legacy mugshot). WSQ is not allowed in Type-10.

  10.021 POA is only for an angled pose (`A`): degrees from full face,
  positive as the subject turns to their left (towards a right profile).
  """

  alias Phantom.Nist.{Field, Record}

  @doc """
  `image` is `%{data:, width:, height:, cga:, csp:}`: the encoded image,
  its compression label (`"PNG"`, `"JPEGB"`) and colour space (`"SRGB"`,
  `"GRAY"`). `opts`: `:src`, `:date`, `:sap`, `:pos` (`F`/`L`/`R`/`A`), and
  `:poa` for `A`.
  """
  @spec build(non_neg_integer(), map(), keyword()) :: %{
          type: 10,
          idc: non_neg_integer(),
          bytes: binary()
        }
  def build(idc, %{data: data} = image, opts) when is_integer(idc) and is_binary(data) do
    pos = Keyword.fetch!(opts, :pos)

    fields =
      [
        {2, Integer.to_string(idc)},
        {3, "FACE"},
        {4, Keyword.fetch!(opts, :src)},
        {5, Field.date(Keyword.fetch!(opts, :date))},
        {6, Integer.to_string(image.width)},
        {7, Integer.to_string(image.height)},
        # SLC 0: no scale; THPS/TVPS are the pixel aspect ratio.
        {8, "0"},
        {9, "1"},
        {10, "1"},
        {11, image.cga},
        {12, image.csp},
        {13, Integer.to_string(Keyword.fetch!(opts, :sap))},
        {20, pos}
      ] ++
        poa(pos, opts[:poa]) ++
        [{999, data}]

    %{type: 10, idc: idc, bytes: Record.encode(10, fields)}
  end

  defp poa("A", angle) when is_integer(angle), do: [{21, Integer.to_string(angle)}]
  defp poa(_pos, _angle), do: []
end
