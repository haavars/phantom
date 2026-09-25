defmodule Phantom.Nist.RecordTest do
  use ExUnit.Case, async: true

  alias Phantom.Nist.Record

  @gs Record.gs()
  @fs Record.fs()
  @rs Record.rs()
  @us Record.us()

  test "encodes field tags, joins fields with GS, and terminates with FS" do
    encoded = Record.encode(9, [{2, "abc"}, {3, "xy"}])

    assert encoded == "9.001:28" <> @gs <> "9.002:abc" <> @gs <> "9.003:xy" <> @fs
  end

  test "the declared length (field TT.001) equals the record's own total byte size" do
    for field_count <- [1, 2, 5], content_size <- [0, 1, 8, 90, 900, 9000] do
      content = String.duplicate("x", content_size)
      fields = for n <- 2..(field_count + 1), do: {n, content}

      encoded = Record.encode(14, fields)

      assert byte_size(encoded) == declared_len(encoded, 14),
             "mismatch for field_count=#{field_count} content_size=#{content_size}"
    end
  end

  test "raw binary content (e.g. an image field) survives byte-for-byte, including separator-valued bytes" do
    image_like = <<0, 1, 28, 29, 30, 31, 255, 254>>

    encoded = Record.encode(14, [{2, "0"}, {999, image_like}])

    assert String.ends_with?(encoded, image_like <> @fs)
    assert byte_size(encoded) == declared_len(encoded, 14)
  end

  test "items/1 and subfields/1 join with the correct hierarchy" do
    assert IO.iodata_to_binary(Record.items(["a", "b", "c"])) == "a" <> @us <> "b" <> @us <> "c"
    assert IO.iodata_to_binary(Record.subfields(["a", "b"])) == "a" <> @rs <> "b"
  end

  describe "decode/1" do
    test "recovers type and every field's raw content, byte-for-byte" do
      encoded = Record.encode(9, [{2, "abc"}, {3, "xy"}])

      assert {:ok, %{type: 9, fields: [{2, "abc"}, {3, "xy"}]}, ""} = Record.decode(encoded)
    end

    test "recovers a trailing binary field exactly, including separator-valued bytes" do
      image_like = <<0, 1, 28, 29, 30, 31, 255, 254>>
      encoded = Record.encode(14, [{2, "0"}, {999, image_like}])

      assert {:ok, %{type: 14, fields: [{2, "0"}, {999, ^image_like}]}, ""} =
               Record.decode(encoded)
    end

    test "leaves whatever follows the record untouched, for decoding a whole transaction" do
      first = Record.encode(1, [{2, "a"}])
      second = Record.encode(2, [{2, "b"}])

      assert {:ok, %{type: 1}, rest} = Record.decode(first <> second)
      assert {:ok, %{type: 2, fields: [{2, "b"}]}, ""} = Record.decode(rest)
    end

    test "round-trips every field-count/content-size combination encode/1's own test does" do
      for field_count <- [1, 2, 5], content_size <- [0, 1, 8, 90, 900, 9000] do
        content = String.duplicate("x", content_size)
        fields = for n <- 2..(field_count + 1), do: {n, content}

        encoded = Record.encode(14, fields)

        assert {:ok, %{type: 14, fields: ^fields}, ""} = Record.decode(encoded)
      end
    end

    test "decodes a real NIST-published conformance sample (BioCTS pass-type-1-mandatory-only.an2)" do
      # Downloaded from https://www.nist.gov/system/files/documents/2016/12/13/biocts_ansi_nist_itl_2.0.6107.19926_sample_data_1.zip
      # (AN2011_SampleData/Traditional Encoding/pass-type-1-mandatory-only.an2)
      # — a real external file, not anything this codec produced itself.
      real_file =
        "1.001:112" <>
          @gs <>
          "1.002:0500" <>
          @gs <>
          "1.003:1" <>
          @us <>
          "1" <>
          @rs <>
          "2" <>
          @us <>
          "0" <>
          @gs <>
          "1.004:A" <>
          @gs <>
          "1.005:20120726" <>
          @gs <>
          "1.007:DAI" <>
          @gs <>
          "1.008:ORI" <>
          @gs <>
          "1.009:TCN" <>
          @gs <>
          "1.011:00.00" <>
          @gs <>
          "1.012:00.00" <>
          @fs <>
          "2.001:17" <> @gs <> "2.002:0" <> @fs

      assert {:ok, [type1, type2]} = Phantom.Nist.File.decode(real_file)

      assert type1.type == 1
      assert {3, "1" <> @us <> "1" <> @rs <> "2" <> @us <> "0"} in type1.fields
      assert {5, "20120726"} in type1.fields
      assert {11, "00.00"} in type1.fields
      assert {12, "00.00"} in type1.fields

      assert type2 == %{type: 2, fields: [{2, "0"}]}
    end

    test "returns an error rather than raising on a truncated record" do
      assert {:error, _reason} = Record.decode("1.001:9999" <> @gs <> "1.002:x" <> @fs)
    end
  end

  defp declared_len(encoded, type) do
    prefix = "#{type}.001:"
    rest = binary_part(encoded, byte_size(prefix), byte_size(encoded) - byte_size(prefix))
    [len_str, _] = :binary.split(rest, @gs)
    String.to_integer(len_str)
  end
end
