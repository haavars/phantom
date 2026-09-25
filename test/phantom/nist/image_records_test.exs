defmodule Phantom.Nist.ImageRecordsTest do
  use ExUnit.Case, async: true

  alias Phantom.Nist.{Record, Type10, Type14, Type15, Type2}

  @print %{data: <<0, 28, 29, 255>>, width: 800, height: 750, ppi: 500, cga: "WSQ20"}
  @face %{data: <<137, 80, 78, 71>>, width: 896, height: 1120, cga: "PNG", csp: "SRGB"}

  defp fields(%{bytes: bytes, type: type}) do
    {:ok, %{type: ^type, fields: fields}, ""} = Record.decode(bytes)
    fields
  end

  test "Type-14 holds the finger position, impression type and capture technology" do
    record =
      Type14.build(3, @print, imp: 1, fgp: 2, src: "PHANTOM", date: ~D[2026-09-25], fct: 2)

    assert %{type: 14, idc: 3} = record

    assert fields(record) == [
             {2, "3"},
             {3, "1"},
             {4, "PHANTOM"},
             {5, "20260925"},
             {6, "800"},
             {7, "750"},
             {8, "1"},
             {9, "500"},
             {10, "500"},
             {11, "WSQ20"},
             {12, "8"},
             {13, "2"},
             {901, "2"},
             {999, <<0, 28, 29, 255>>}
           ]
  end

  test "Type-15 holds the palm position in 15.013 and a palm impression type" do
    record = Type15.build(4, @print, imp: 11, fgp: 22, src: "PHANTOM", date: ~D[2026-09-25])

    assert %{type: 15, idc: 4} = record
    fields = fields(record)
    assert {3, "11"} in fields
    assert {13, "22"} in fields
    refute List.keymember?(fields, 901, 0)
    assert List.last(fields) == {999, @print.data}
  end

  test "Type-10 is a face with no physical scale, a subject acquisition profile and a pose" do
    record = Type10.build(1, @face, src: "PHANTOM", date: ~D[2026-09-25], sap: 20, pos: "F")

    assert fields(record) == [
             {2, "1"},
             {3, "FACE"},
             {4, "PHANTOM"},
             {5, "20260925"},
             {6, "896"},
             {7, "1120"},
             {8, "0"},
             {9, "1"},
             {10, "1"},
             {11, "PNG"},
             {12, "SRGB"},
             {13, "20"},
             {20, "F"},
             {999, @face.data}
           ]
  end

  test "Type-10 has a pose offset angle only for an angled pose" do
    angled = Type10.build(1, @face, src: "P", date: ~D[2026-09-25], sap: 20, pos: "A", poa: -45)
    assert {21, "-45"} in fields(angled)

    profile = Type10.build(1, @face, src: "P", date: ~D[2026-09-25], sap: 20, pos: "L", poa: -45)
    refute List.keymember?(fields(profile), 21, 0)
  end

  test "Type-2 holds the IDC and the given fields" do
    record = Type2.build(0, [{3, "PH-1"}, {4, "SYNTHETIC"}])
    assert fields(record) == [{2, "0"}, {3, "PH-1"}, {4, "SYNTHETIC"}]
  end
end
