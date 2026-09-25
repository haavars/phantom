defmodule Phantom.Nist.Record do
  @moduledoc """
  One ANSI/NIST-ITL 1-2011 (Update:2015) tagged-field logical record, in
  Traditional encoding: the byte-level layer every `Phantom.Nist.TypeN`
  module builds on. Copied from abis_next (`AbisNext.Nist.Record`, commit
  8ee0b48), which checked it against NIST SP 500-290 Ed. 3 and NIST's
  BioCTS sample files.

  A transaction is `R1 FS R2 FS ... Rn FS` and a record is
  `FN1:IF1 GS FN2:IF2 GS ... FNn:IFn FS`, so an encoded record carries its
  own trailing separator. The four separators nest: FS > GS > RS > US.

  Every record starts with `TT.001`, its own length in bytes *including the
  digits of that length*, which `encode/2` finds as a fixed point. `decode/1`
  slices exactly that many bytes rather than scanning for separators,
  because the image field (`TT.999`, always last) can contain separator
  bytes.
  """

  @fs <<28>>
  @gs <<29>>
  @rs <<30>>
  @us <<31>>

  @doc "The File Separator (0x1C): ends each logical record."
  def fs, do: @fs
  @doc "The Group Separator (0x1D): separates fields within a record."
  def gs, do: @gs
  @doc "The Record Separator (0x1E): separates repeated subfields within a field."
  def rs, do: @rs
  @doc "The Unit Separator (0x1F): separates information items within a subfield."
  def us, do: @us

  @doc "Joins information items with the Unit Separator."
  @spec items([iodata()]) :: iodata()
  def items(list), do: Enum.intersperse(list, @us)

  @doc "Joins subfields with the Record Separator."
  @spec subfields([iodata()]) :: iodata()
  def subfields(list), do: Enum.intersperse(list, @rs)

  @doc """
  Encodes one logical record of `type` from `fields`, an ordered list of
  `{field_number, content}` without the `TT.001` length field, which is
  computed and prepended here. `content` is already formatted (text, or raw
  binary for the `999` image field).
  """
  @spec encode(pos_integer(), [{pos_integer(), iodata()}]) :: binary()
  def encode(type, fields) when is_integer(type) and is_list(fields) do
    type_str = Integer.to_string(type)

    tagged =
      Enum.map(fields, fn {number, content} ->
        [type_str, ".", pad3(number), ":", content]
      end)

    body_after_len = IO.iodata_to_binary([Enum.intersperse(tagged, @gs), @fs])

    # "<type>.001:", the fixed part of the length field's own tag.
    header_prefix_size = byte_size(type_str) + 5

    len_digits = find_len_digits(header_prefix_size, body_after_len, 1)

    IO.iodata_to_binary([type_str, ".001:", len_digits, @gs, body_after_len])
  end

  # `d` is the guess for how many digits the length needs; the total grows
  # with `d`, so this settles on the fixed point in one or two steps.
  defp find_len_digits(header_prefix_size, body_after_len, d) do
    total = header_prefix_size + d + byte_size(@gs) + byte_size(body_after_len)
    digits = Integer.to_string(total)

    if byte_size(digits) == d do
      digits
    else
      find_len_digits(header_prefix_size, body_after_len, byte_size(digits))
    end
  end

  defp pad3(n), do: n |> Integer.to_string() |> String.pad_leading(3, "0")

  @doc """
  Decodes one logical record from the front of `binary`. Returns its `type`,
  its fields as raw `{field_number, content}` (subfields still
  separator-joined), and the bytes after it.
  """
  @spec decode(binary()) ::
          {:ok, %{type: pos_integer(), fields: [{pos_integer(), binary()}]}, binary()}
          | {:error, term()}
  def decode(binary) when is_binary(binary) do
    with {:ok, type, len} <- parse_header(binary),
         true <- byte_size(binary) >= len do
      record = binary_part(binary, 0, len)
      rest = binary_part(binary, len, byte_size(binary) - len)
      # Strip the trailing FS, then the TT.001 field up to its GS.
      body = binary_part(record, 0, len - byte_size(@fs))
      {_len_field, fields_body} = split_first(body, @gs)

      case parse_fields(fields_body) do
        {:ok, fields} -> {:ok, %{type: type, fields: fields}, rest}
        :error -> {:error, :malformed_record}
      end
    else
      _ -> {:error, :malformed_record}
    end
  end

  defp parse_header(binary) do
    with {gs_pos, _} <- :binary.match(binary, @gs),
         header = binary_part(binary, 0, gs_pos),
         [type_and_001, len_str] <- String.split(header, ":", parts: 2),
         [type_str, "001"] <- String.split(type_and_001, ".", parts: 2),
         {type, ""} <- Integer.parse(type_str),
         {len, ""} <- Integer.parse(len_str) do
      {:ok, type, len}
    else
      _ -> :error
    end
  end

  defp parse_fields(<<>>), do: {:ok, []}

  defp parse_fields(binary) do
    with [tag, rest] <- String.split(binary, ":", parts: 2),
         [_type_str, field_str] <- String.split(tag, ".", parts: 2),
         {field_number, ""} <- Integer.parse(field_str) do
      if field_number == 999 do
        {:ok, [{999, rest}]}
      else
        {content, remaining} = split_first(rest, @gs)

        case parse_fields(remaining) do
          {:ok, rest_fields} -> {:ok, [{field_number, content} | rest_fields]}
          :error -> :error
        end
      end
    else
      _ -> :error
    end
  end

  defp split_first(binary, sep) do
    case :binary.split(binary, sep) do
      [content, remaining] -> {content, remaining}
      [content] -> {content, <<>>}
    end
  end
end
