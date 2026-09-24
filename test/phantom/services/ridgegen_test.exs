defmodule Phantom.Services.RidgegenTest do
  use ExUnit.Case, async: true

  import Phantom.BiometricsFixtures

  alias Phantom.Services.Ridgegen

  test "renders an image and returns its ground truth" do
    stub_ridge(notify: self())

    assert {:ok, %{image: image, width: 800, ppi: 500, meta: meta}} =
             Ridgegen.render("finger", 3, 42, 1, label: "subject_001")

    assert image == png()
    assert meta["pattern"] == "whorl"

    assert_received {:ridge_render,
                     %{
                       "kind" => "finger",
                       "code" => 3,
                       "seed" => 42,
                       "capture" => 1,
                       "label" => "subject_001"
                     }}
  end

  test "reports service errors and an unreachable service" do
    Req.Test.stub(Ridgegen, &Plug.Conn.send_resp(&1, 400, "unsupported kind/code"))
    assert {:error, message} = Ridgegen.render("finger", 11, 1, 0)
    assert message =~ "HTTP 400"

    Req.Test.stub(Ridgegen, &Req.Test.transport_error(&1, :econnrefused))
    assert {:error, message} = Ridgegen.render("finger", 1, 1, 0)
    assert message =~ "python_biometrics/server.py"
    assert Ridgegen.health() == :unreachable
  end

  test "health/0 is :ready when the service says so" do
    stub_ridge()
    assert Ridgegen.health() == :ready
  end
end
