defmodule Phantom.Nist.Type15 do
  @moduledoc """
  A Type-15 variable-resolution palm print image record. Same shape as
  `Phantom.Nist.Type14` (NIST SP 500-290 Ed. 3, Section 8.15), with the palm
  position in 15.013 FGP (codes 20-38) and 15.005 as the palm capture date.

  15.003 IMP takes the palm codes only (10 palm live-scan, 11 palm
  non-live-scan, 24/25/28/29/41/42), not Table 8's finger codes.
  """

  alias Phantom.Nist.{Field, Record}

  @doc """
  `image` is `%{data:, width:, height:, ppi:, cga:}`. `opts`: `:imp`, `:fgp`
  (the palm position), `:src`, `:date`, and optionally `:fct`.
  """
  @spec build(non_neg_integer(), map(), keyword()) :: %{
          type: 15,
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

    %{type: 15, idc: idc, bytes: Record.encode(15, fields)}
  end
end
