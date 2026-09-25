defmodule Phantom.Nist.FileTest do
  use ExUnit.Case, async: true

  alias Phantom.Nist.{File, Record, Type1, Type14, Type2}

  @image %{data: <<1, 2, 3>>, width: 10, height: 8, ppi: 500, cga: "PNG"}
  @type14 [imp: 1, fgp: 2, src: "PHANTOM", date: ~D[2026-01-01]]

  defp type1(pairs),
    do: Type1.build(pairs, tot: "A", dai: "D", ori: "O", tcn: "T", date: ~D[2026-01-01])

  test "encode/1 concatenates records in order" do
    type2 = Type2.build(0, [{3, "case 7"}])
    type1 = type1([{2, 0}])

    assert File.encode([type1, type2]) == type1.bytes <> type2.bytes
  end

  test "decode/1 recovers every record encode/1 produced, in order" do
    type2 = Type2.build(0, [{3, "case 7"}])
    type14 = Type14.build(1, @image, @type14)

    assert {:ok, [decoded1, decoded2, decoded14]} =
             File.decode(File.encode([type1([{2, 0}, {14, 1}]), type2, type14]))

    assert decoded1.type == 1
    assert decoded2 == %{type: 2, fields: [{2, "0"}, {3, "case 7"}]}
    assert decoded14.type == 14
    assert {999, <<1, 2, 3>>} in decoded14.fields
    assert {6, "10"} in decoded14.fields
    assert {7, "8"} in decoded14.fields
  end

  test "decode/1 errors on a malformed transaction rather than returning a partial list" do
    assert {:error, _reason} = File.decode("not a nist transaction at all")
  end

  test "decode/1 on an empty transaction returns an empty list" do
    assert {:ok, []} = File.decode(<<>>)
  end

  test "decode/1 errors when the records don't match Type-1's CNT" do
    type2 = Type2.build(0, [{3, "unexpected"}])

    assert {:error, {:unexpected_trailing_bytes, _}} =
             File.decode(File.encode([type1([]), type2]))

    assert {:error, {:unexpected_record, 14, 2}} =
             File.decode(File.encode([type1([{14, 1}]), type2]))
  end

  test "decode/1 needs a Type-1 record first" do
    assert {:error, :no_type1} = File.decode(Record.encode(2, [{2, "0"}]))
  end
end
