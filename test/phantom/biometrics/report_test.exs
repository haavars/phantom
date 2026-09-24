defmodule Phantom.Biometrics.ReportTest do
  use ExUnit.Case, async: true

  alias Phantom.Biometrics.Report

  test "stats ignore missing values" do
    assert Report.stats([3, 1, nil, 2, 4]) ==
             %{"count" => 4, "mean" => 2.5, "min" => 1, "p10" => 1, "median" => 2, "max" => 4}

    assert Report.stats([nil]) == %{"count" => 0}
  end

  test "no report without verified shots" do
    subject = %{id: "subject_001", shots: [%{status: "ok", meta: %{"pattern" => "whorl"}}]}
    assert Report.build("unused", [subject]) == nil
  end
end
