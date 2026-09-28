defmodule Phantom.Biometrics.UnifyTest do
  # Changes the application's Unify settings.
  use Phantom.DataCase, async: false

  import Phantom.BiometricsFixtures

  alias Phantom.Biometrics
  alias Phantom.Biometrics.{NistExport, NistImages, Unify}
  alias Phantom.Nist.Record

  @wsq if NistImages.wsq_available?(),
         do: [],
         else: [skip: "needs NIST's cwsq (python_biometrics/setup.sh)"]

  setup do
    previous = Application.get_env(:phantom, Unify)
    on_exit(fn -> Application.put_env(:phantom, Unify, previous || []) end)
  end

  test "defaults are placeholders; set ones replace them" do
    Application.put_env(:phantom, Unify, tot_enrol: nil, ori: "")
    settings = Unify.settings()

    assert %{tot_enrol: "ENROL", ori: "PHANTOM", version: "0502", face_sap: 30} = settings
    assert settings.capture == "ink"
    assert Unify.placeholders(settings) == [:tot_enrol, :tot_search, :dai, :ori, :domain]

    Application.put_env(:phantom, Unify,
      tot_enrol: "CPS",
      tot_search: "SRE",
      dai: "NOUNIFY01",
      ori: "NOPHANTOM",
      domain: "NORAM",
      face_sap: "32",
      capture: "livescan"
    )

    settings = Unify.settings()
    assert %{tot_enrol: "CPS", dai: "NOUNIFY01", face_sap: 32, capture: "livescan"} = settings
    assert Unify.placeholders(settings) == []
  end

  test "impression codes for ink and live-scan" do
    assert Enum.map([:rolled, :plain, :palm], &Unify.impression("ink", &1)) == [3, 2, 11]
    assert Enum.map([:rolled, :plain, :palm], &Unify.impression("livescan", &1)) == [1, 0, 10]
  end

  @tag @wsq
  test "the Unify target's header carries the ICD settings" do
    Application.put_env(:phantom, Unify,
      tot_enrol: "CPS",
      dai: "NOUNIFY01",
      ori: "NOPHANTOM",
      domain: "NORAM",
      domain_version: "7",
      version: "0400"
    )

    run = create_run(subjects: 1, shots: ["rolled_02"])
    {:ok, export} = Biometrics.nist_export(run, "subject_001", %{target: "unify"})
    assert export.compression == "wsq"
    [enrol] = export.transactions

    # Type-1 and Type-2 come first, before any image is read.
    [type1, type2] = export |> NistExport.transaction_stream(enrol) |> Enum.take(2)
    {:ok, type1, ""} = Record.decode(type1)
    {:ok, type2, ""} = Record.decode(type2)
    type1 = Map.new(type1.fields)

    assert %{2 => "0400", 4 => "CPS", 7 => "NOUNIFY01", 8 => "NOPHANTOM"} = type1
    assert type1[13] == "NORAM" <> Record.us() <> "7"
    assert %{5 => "CPS"} = Map.new(type2.fields)
  end
end
