defmodule Phantom.Nist.Type14 do
  @moduledoc """
  A Type-14 variable-resolution fingerprint image record: one rolled finger
  or one slap. Based on abis_next's `AbisNext.Nist.Type14` (commit 8ee0b48),
  with the impression type, finger position and source as arguments rather
  than "unknown".

  Emits the mandatory fields and the ones that depend on image data (NIST
  SP 500-290 Ed. 3, Table 104), plus 14.901 FCT, the capture technology
  Update:2015 split out of IMP.
  """

  alias Phantom.Nist.{Field, Record}

  @doc """
  `image` is `%{data:, width:, height:, ppi:, cga:}`: the encoded image and
  its compression label (`"PNG"`, `"WSQ20"`). `opts`: `:imp` (Table 8),
  `:fgp` (Table 9), `:src`, `:date`, and optionally `:fct` (Table 11).
  """
  @spec build(non_neg_integer(), map(), keyword()) :: %{
          type: 14,
          idc: non_neg_integer(),
          bytes: binary()
        }
  def build(idc, %{data: data} = image, opts) when is_integer(idc) and is_binary(data) do
    ppi = Integer.to_string(image.ppi)

    fields =
      [
        {2, Integer.to_string(idc)},
        {3, Integer.to_string(Keyword.fetch!(opts, :imp))},
        {4, Keyword.fetch!(opts, :src)},
        {5, Field.date(Keyword.fetch!(opts, :date))},
        {6, Integer.to_string(image.width)},
        {7, Integer.to_string(image.height)},
        # SLC 1: pixels per inch.
        {8, "1"},
        {9, ppi},
        {10, ppi},
        {11, image.cga},
        {12, "8"},
        {13, Integer.to_string(Keyword.fetch!(opts, :fgp))}
      ] ++
        if(opts[:fct], do: [{901, Integer.to_string(opts[:fct])}], else: []) ++
        [{999, data}]

    %{type: 14, idc: idc, bytes: Record.encode(14, fields)}
  end
end
