defmodule Phantom.Biometrics.Unify do
  @moduledoc """
  Settings for the NIST export's Unify 5.2 target (`Phantom.Biometrics.NistExport`,
  target `"unify"`). What Unify needs is in `docs/phantom_an2_unify_import.md`;
  the values that depend on the project ICD come from config, which
  `config/runtime.exs` reads from `UNIFY_*` environment variables (or `.env`
  in dev):

  | Key | Variable | Field | Default |
  |---|---|---|---|
  | `:tot_enrol` | `UNIFY_TOT_ENROL` | 1.004 TOT of an enrolment, and 2.005 | `ENROL` |
  | `:tot_search` | `UNIFY_TOT_SEARCH` | 1.004 TOT of a search, and 2.005 | `SEARCH` |
  | `:dai` | `UNIFY_DAI` | 1.007 DAI, the receiving Unify system | `PHANTOM` |
  | `:ori` | `UNIFY_ORI` | 1.008 ORI and every image's SRC | `PHANTOM` |
  | `:domain` | `UNIFY_DOMAIN` | 1.013 DOM name | `PHANTOM` |
  | `:domain_version` | `UNIFY_DOMAIN_VERSION` | 1.013 DOM version | `1` |
  | `:version` | `UNIFY_VERSION` | 1.002 VER, which must fit the domain | `0502` |
  | `:face_sap` | `UNIFY_FACE_SAP` | 10.013 SAP of the mugshots | `30` |
  | `:capture` | `UNIFY_CAPTURE` | IMP of prints and palms: `ink` or `livescan` | `ink` |

  The defaults for TOT, DAI, ORI and DOM are placeholders Unify won't
  accept; `placeholders/0` lists the ones still set to them, and the export
  page says so.
  """

  @defaults %{
    tot_enrol: "ENROL",
    tot_search: "SEARCH",
    dai: "PHANTOM",
    ori: "PHANTOM",
    domain: "PHANTOM",
    domain_version: "1",
    version: "0502",
    face_sap: 30,
    capture: "ink"
  }

  # Settings Unify rejects until they're set from the ICD.
  @icd [:tot_enrol, :tot_search, :dai, :ori, :domain]

  @doc "The settings: config over the defaults."
  def settings do
    config = Map.new(Application.get_env(:phantom, __MODULE__, []))

    @defaults
    |> Map.merge(Map.reject(config, fn {_key, value} -> value in [nil, ""] end))
    |> Map.update!(:face_sap, &to_integer/1)
    |> Map.update!(:capture, &if(&1 == "livescan", do: "livescan", else: "ink"))
  end

  @doc "The ICD settings still at their placeholder defaults, e.g. `[:tot_enrol, :ori]`."
  def placeholders(settings \\ settings()) do
    Enum.filter(@icd, &(settings[&1] == @defaults[&1]))
  end

  @doc """
  15.003/14.003 IMP in the base standard's codes, which Unify maps to a
  capture type: `ink` gives non-live-scan rolled 3, plain 2 and palm 11;
  `livescan` gives 1, 0 and 10.
  """
  def impression("ink", :rolled), do: 3
  def impression("ink", :plain), do: 2
  def impression("ink", :palm), do: 11
  def impression("livescan", :rolled), do: 1
  def impression("livescan", :plain), do: 0
  def impression("livescan", :palm), do: 10

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value), do: String.to_integer(value)
end
