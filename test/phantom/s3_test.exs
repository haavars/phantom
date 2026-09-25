defmodule Phantom.S3Test do
  use ExUnit.Case, async: true

  alias Phantom.S3

  @moduletag :tmp_dir

  test "uploads a file streamed from disk, signed, with its headers", %{tmp_dir: dir} do
    path = Path.join(dir, "export.zip")
    File.write!(path, :binary.copy("x", 3_000_000))

    Req.Test.stub(S3, fn conn ->
      assert conn.method == "PUT"
      assert conn.host == "s3.test"
      assert conn.request_path == "/phantom-test/exports/2026-09-25/abc/PH-1_synthetic.zip"
      assert Plug.Conn.get_req_header(conn, "content-length") == ["3000000"]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/zip"]
      assert Plug.Conn.get_req_header(conn, "x-amz-content-sha256") == ["UNSIGNED-PAYLOAD"]
      assert [auth] = Plug.Conn.get_req_header(conn, "authorization")
      assert auth =~ ~r"^AWS4-HMAC-SHA256 Credential=test-key/\d{8}/auto/s3/aws4_request"

      {:ok, body, conn} = read_all(conn)
      assert byte_size(body) == 3_000_000
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert :ok =
             S3.put_file("exports/2026-09-25/abc/PH-1_synthetic.zip", path,
               content_type: "application/zip"
             )
  end

  test "says why S3 refused", %{tmp_dir: dir} do
    path = Path.join(dir, "f")
    File.write!(path, "data")

    Req.Test.stub(S3, fn conn ->
      Plug.Conn.send_resp(conn, 403, "<Error><Code>AccessDenied</Code></Error>")
    end)

    assert {:error, "S3 answered 403: AccessDenied"} = S3.put_file("k", path)
    assert {:error, "S3 answered 403: AccessDenied"} = S3.delete("k")
  end

  test "presigns a GET URL, for at most 7 days" do
    url = S3.presign("exports/2026-09-25/abc/PH-1 synthetic.zip", 3600)
    uri = URI.parse(url)
    query = URI.decode_query(uri.query)

    assert uri.host == "s3.test"
    assert uri.path == "/phantom-test/exports/2026-09-25/abc/PH-1%20synthetic.zip"
    assert query["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256"
    assert query["X-Amz-Expires"] == "3600"
    assert query["X-Amz-Credential"] =~ ~r"^test-key/\d{8}/auto/s3/aws4_request$"
    assert query["X-Amz-Signature"] =~ ~r/^[0-9a-f]{64}$/

    assert_raise FunctionClauseError, fn -> S3.presign("k", 7 * 24 * 3600 + 1) end
  end

  test "is configured in tests" do
    assert S3.configured?()
  end

  defp read_all(conn, acc \\ []) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> {:ok, IO.iodata_to_binary([acc, body]), conn}
      {:more, body, conn} -> read_all(conn, [acc, body])
    end
  end
end
