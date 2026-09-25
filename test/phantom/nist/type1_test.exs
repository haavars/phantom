defmodule Phantom.Nist.Type1Test do
  use ExUnit.Case, async: true

  alias Phantom.Nist.{Record, Type1}

  @gs Record.gs()
  @us Record.us()
  @rs Record.rs()

  @opts [tot: "ENROL", dai: "PHANTOM", ori: "PHANTOM", tcn: "PH-1-ENROL", date: ~D[2026-09-11]]

  defp fields(record) do
    {:ok, %{type: 1, fields: fields}, ""} = Record.decode(record.bytes)
    fields
  end

  test "field 1.003 CNT is FRC/CRC, then a (REC, IDC) subfield per other record" do
    record = Type1.build([{2, 0}, {14, 1}], @opts)

    assert {3, "1" <> @us <> "2" <> @rs <> "2" <> @us <> "0" <> @rs <> "14" <> @us <> "1"} in fields(
             record
           )

    assert Type1.decode_cnt(elem(List.keyfind(fields(record), 3, 0), 1)) ==
             {:ok, [{2, 0}, {14, 1}]}
  end

  test "writes the mandatory fields: Update:2015 version, TOT, date, agencies, TCN, NSR and NTR" do
    record = Type1.build([{14, 1}], @opts)

    assert [
             {2, "0502"},
             {3, _cnt},
             {4, "ENROL"},
             {5, "20260911"},
             {7, "PHANTOM"},
             {8, "PHANTOM"},
             {9, "PH-1-ENROL"},
             {11, "00.00"},
             {12, "00.00"}
           ] = fields(record)

    assert record.bytes =~ "1.005:20260911" <> @gs
  end

  test "1.013 DOM names the domain and its version, when given" do
    record = Type1.build([], Keyword.put(@opts, :domain, {"PHANTOM", "1"}))
    assert {13, "PHANTOM" <> @us <> "1"} in fields(record)
  end
end
