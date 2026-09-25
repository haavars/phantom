defmodule Phantom.Nist.Type1 do
  @moduledoc """
  The Type-1 transaction information record: exactly one per transaction,
  always first. Copied from abis_next (`AbisNext.Nist.Type1`, commit
  8ee0b48), which emits the fields NIST SP 500-290 Ed. 3 Table 34 marks
  mandatory; Phantom adds 1.013 DOM, which names the Type-2 layout.

  1.011 NSR and 1.012 NTR are `00.00`, the standard's value when a
  transaction has no Type-4 records.
  """

  alias Phantom.Nist.{Field, Record}

  # ANSI/NIST-ITL 1-2011 Update:2015.
  @version "0502"

  @doc """
  `record_pairs` is `{record_type, idc}` for every other record in the
  transaction, in order (field 1.003 CNT).

  `opts`: `:tot` (1.004, up to 16 letters), `:date` (1.005, a `Date`), `:dai`
  and `:ori` (1.007/1.008), `:tcn` (1.009), and optionally `:domain`, a
  `{name, version}` for 1.013 DOM.
  """
  @spec build([{pos_integer(), non_neg_integer()}], keyword()) :: %{
          type: 1,
          idc: nil,
          bytes: binary()
        }
  def build(record_pairs, opts) when is_list(record_pairs) do
    fields =
      [
        {2, @version},
        {3, cnt(record_pairs)},
        {4, Keyword.fetch!(opts, :tot)},
        {5, Field.date(Keyword.fetch!(opts, :date))},
        {7, Keyword.fetch!(opts, :dai)},
        {8, Keyword.fetch!(opts, :ori)},
        {9, Keyword.fetch!(opts, :tcn)},
        {11, "00.00"},
        {12, "00.00"}
      ] ++ domain(opts[:domain])

    %{type: 1, idc: nil, bytes: Record.encode(1, fields)}
  end

  defp domain(nil), do: []
  defp domain({name, version}), do: [{13, Record.items([name, version])}]

  # First subfield: FRC ("1") and CRC (how many other records); then one
  # (REC, IDC) subfield per record.
  defp cnt(record_pairs) do
    meta = Record.items(["1", Integer.to_string(length(record_pairs))])

    pairs =
      Enum.map(record_pairs, fn {rec, idc} ->
        Record.items([Integer.to_string(rec), Integer.to_string(idc)])
      end)

    Record.subfields([meta | pairs])
  end

  @doc "Decodes field 1.003 CNT back into the `[{record_type, idc}]` list."
  @spec decode_cnt(binary()) :: {:ok, [{pos_integer(), non_neg_integer()}]} | {:error, term()}
  def decode_cnt(cnt_bytes) when is_binary(cnt_bytes) do
    case String.split(cnt_bytes, Record.rs()) do
      [_meta | pairs] -> decode_pairs(pairs, [])
      _ -> {:error, :malformed_cnt}
    end
  end

  defp decode_pairs([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_pairs([pair | rest], acc) do
    with [rec_str, idc_str] <- String.split(pair, Record.us()),
         {rec, ""} <- Integer.parse(rec_str),
         {idc, ""} <- Integer.parse(idc_str) do
      decode_pairs(rest, [{rec, idc} | acc])
    else
      _ -> {:error, :malformed_cnt}
    end
  end
end
