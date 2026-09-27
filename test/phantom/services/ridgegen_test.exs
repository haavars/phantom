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

  test "face_template/1 returns the template of the face in an image, or none" do
    stub_ridge(embed: fn -> %{faces: 2, det: 0.87, template: face_template(3)} end)
    assert {:ok, %{faces: 2, det: 0.87, template: template}} = Ridgegen.face_template(png())
    assert byte_size(template) == 512 * 4
    assert template == Base.decode64!(face_template(3))

    stub_ridge(embed: fn -> %{faces: 0} end)
    assert Ridgegen.face_template(png()) == {:ok, %{faces: 0}}

    stub_ridge(embed: fn -> {503, %{detail: "InsightFace isn't installed"}} end)
    assert {:error, message} = Ridgegen.face_template(png())
    assert message =~ "HTTP 503"
  end

  test "health/0 is :ready when the service says so" do
    stub_ridge()
    assert Ridgegen.health() == :ready
  end
end
