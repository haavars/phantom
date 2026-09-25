defmodule Phantom.Nist.File do
  @moduledoc """
  Joins encoded `Phantom.Nist.TypeN` records into one transaction, and splits
  a transaction back into `Phantom.Nist.Record.decode/1`'s raw records.
  Copied from abis_next (`AbisNext.Nist.File`, commit 8ee0b48) without its
  legacy binary (Type-4 to 8) decoding, which Phantom never writes.

  Records carry their own trailing separator, so joining is concatenation.
  `decode/1` reads the Type-1 record's CNT field and checks that exactly the
  records it lists follow.
  """

  alias Phantom.Nist.{Record, Type1}

  @doc "The bytes of `records` (maps with `:bytes`, Type-1 first), in order."
  @spec encode([%{bytes: binary()}]) :: binary()
  def encode(records) when is_list(records) do
    records
    |> Enum.map(& &1.bytes)
    |> IO.iodata_to_binary()
  end

  @doc """
  Decodes a transaction into its records, in order. Fails on the first
  malformed record, or when the records don't match Type-1's CNT.
  """
  @spec decode(binary()) :: {:ok, [%{type: pos_integer(), fields: [tuple()]}]} | {:error, term()}
  def decode(<<>>), do: {:ok, []}

  def decode(binary) when is_binary(binary) do
    with {:ok, %{type: 1} = type1, rest} <- Record.decode(binary),
         {3, cnt} <- List.keyfind(type1.fields, 3, 0),
         {:ok, schedule} <- Type1.decode_cnt(cnt) do
      decode_scheduled(rest, schedule, [type1])
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :no_type1}
    end
  end

  defp decode_scheduled(<<>>, [], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_scheduled(binary, [], _acc),
    do: {:error, {:unexpected_trailing_bytes, byte_size(binary)}}

  defp decode_scheduled(binary, [{type, _idc} | schedule], acc) do
    case Record.decode(binary) do
      {:ok, %{type: ^type} = record, rest} -> decode_scheduled(rest, schedule, [record | acc])
      {:ok, %{type: other}, _rest} -> {:error, {:unexpected_record, type, other}}
      {:error, reason} -> {:error, reason}
    end
  end
end
