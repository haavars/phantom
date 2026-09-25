defmodule Phantom.Nist.Field do
  @moduledoc "Content formats shared by the `Phantom.Nist.TypeN` builders."

  @doc "A `Date` as `YYYYMMDD`, the Traditional-encoding date format (SP 500-290 Ed. 3, 7.7.2.3)."
  @spec date(Date.t()) :: String.t()
  def date(%Date{} = date), do: Calendar.strftime(date, "%Y%m%d")
end
