defmodule Phantom.ImageGenerationTest do
  use ExUnit.Case, async: true

  alias Phantom.ImageGeneration

  @fake_png <<137, 80, 78, 71, 13, 10, 26, 10>> <> "not-a-real-png-but-good-enough-for-tests"

  test "rejects a blank prompt without calling the service" do
    assert {:error, "Prompt can't be blank."} = ImageGeneration.generate("")
  end

  test "saves the generated image and returns its public path" do
    Req.Test.stub(Phantom.ImageGeneration, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-seed", "7")
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, @fake_png)
    end)

    assert {:ok, result} = ImageGeneration.generate("a cat", aspect_ratio: "16:9", steps: 20)
    assert result.prompt == "a cat"
    assert result.seed == "7"
    assert String.starts_with?(result.path, "/uploads/")

    saved_path = Path.join([:code.priv_dir(:phantom), "static", result.path])
    assert File.read!(saved_path) == @fake_png
    File.rm!(saved_path)
  end

  test "surfaces a helpful error when the service is unreachable" do
    Req.Test.stub(Phantom.ImageGeneration, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, message} = ImageGeneration.generate("a cat")
    assert message =~ "python_inference/server.py"
  end

  test "sends reference images as multipart file fields" do
    Req.Test.stub(Phantom.ImageGeneration, fn conn ->
      conn =
        Plug.Parsers.call(
          conn,
          Plug.Parsers.init(parsers: [Plug.Parsers.MULTIPART], length: 20_000_000)
        )

      # Plug represents a single occurrence of a repeated multipart field as a
      # bare value rather than a one-element list (unlike Starlette/FastAPI,
      # which the real service uses and always gives a list) - normalize.
      assert [%Plug.Upload{filename: "ref.png", content_type: "image/png"} = upload] =
               List.wrap(conn.params["images"])

      assert File.read!(upload.path) == @fake_png

      conn
      |> Plug.Conn.put_resp_header("x-seed", "3")
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, @fake_png)
    end)

    images = [%{data: @fake_png, filename: "ref.png", content_type: "image/png"}]

    assert {:ok, result} =
             ImageGeneration.generate("put the hat from the reference on the cat", images: images)

    saved_path = Path.join([:code.priv_dir(:phantom), "static", result.path])
    File.rm!(saved_path)
  end

  test "rejects more than the maximum number of reference images without calling the service" do
    images =
      for n <- 1..(ImageGeneration.max_reference_images() + 1) do
        %{data: @fake_png, filename: "ref-#{n}.png", content_type: "image/png"}
      end

    assert {:error, message} = ImageGeneration.generate("a cat", images: images)
    assert message =~ "at most #{ImageGeneration.max_reference_images()}"
  end

  describe "health/0" do
    test "returns :ready when the service reports it's ready" do
      stub_health(%{status: "ready"})
      assert ImageGeneration.health() == :ready
    end

    test "returns :loading while the model is still loading" do
      stub_health(%{status: "loading"})
      assert ImageGeneration.health() == :loading
    end

    test "returns an error tuple when the service failed to load" do
      stub_health(%{status: "error", error: "out of memory"})
      assert ImageGeneration.health() == {:error, "out of memory"}
    end

    test "returns :unreachable when the service can't be reached" do
      Req.Test.stub(Phantom.ImageGeneration, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert ImageGeneration.health() == :unreachable
    end

    defp stub_health(body) do
      Req.Test.stub(Phantom.ImageGeneration, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)
    end
  end
end
