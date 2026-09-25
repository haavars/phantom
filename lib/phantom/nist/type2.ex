defmodule Phantom.Nist.Type2 do
  @moduledoc """
  A Type-2 user-defined descriptive text record. The standard only fixes
  2.002 IDC; the fields from 2.003 up belong to the domain named in the
  Type-1 record's 1.013 DOM. `Phantom.Biometrics.NistExport` defines
  Phantom's layout.
  """

  alias Phantom.Nist.Record

  @doc "`fields` are `{field_number, text}` from 3 up, in order."
  @spec build(non_neg_integer(), [{pos_integer(), String.t()}]) :: %{
          type: 2,
          idc: non_neg_integer(),
          bytes: binary()
        }
  def build(idc, fields) when is_integer(idc) and is_list(fields) do
    %{type: 2, idc: idc, bytes: Record.encode(2, [{2, Integer.to_string(idc)} | fields])}
  end
end
