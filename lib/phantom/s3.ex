defmodule Phantom.S3 do
  @moduledoc """
  A small client for an S3-compatible bucket (Cloudflare R2, AWS S3, MinIO),
  used to share exports as links (`Phantom.Biometrics.Shares`). Requests are
  signed with Req's built-in AWS Signature v4; objects are addressed
  path-style, `<endpoint>/<bucket>/<key>`.

  Configured with `config :phantom, Phantom.S3` (set from the environment in
  `config/runtime.exs`):

    * `:bucket` - unset turns sharing off
    * `:endpoint` - e.g. `https://<account id>.r2.cloudflarestorage.com`
    * `:region` - `"auto"` for R2
    * `:access_key_id`, `:secret_access_key`

  `config :phantom, :s3_req_options` adds Req options, e.g. a `Req.Test` plug
  in tests.
  """

  # SigV4 presigned URLs can't last longer than 7 days.
  @max_expires 7 * 24 * 3600

  @doc "Whether a bucket is configured."
  def configured? do
    config = config()
    Enum.all?([:bucket, :endpoint, :access_key_id, :secret_access_key], &present?(config[&1]))
  end

  defp present?(value), do: is_binary(value) and value != ""

  @doc """
  Uploads the file at `path` to `key`, streamed from disk. `headers` are
  added to the request, e.g. `content_type:` and `content_disposition:`,
  which S3 stores and sends back with the object.
  """
  def put_file(key, path, headers \\ []) do
    %File.Stat{size: size} = File.stat!(path)

    [
      method: :put,
      url: object_url(key),
      headers: [content_length: to_string(size)] ++ headers,
      body: File.stream!(path, 1024 * 1024)
    ]
    |> request()
    |> ok()
  end

  @doc "Deletes the object at `key`. Deleting what isn't there is `:ok` too."
  def delete(key), do: [method: :delete, url: object_url(key)] |> request() |> ok()

  @doc """
  A presigned GET URL for `key` that works without credentials for
  `expires_in` seconds (at most 7 days).
  """
  def presign(key, expires_in) when expires_in in 1..@max_expires//1 do
    config = config()

    Req.Utils.aws_sigv4_url(
      access_key_id: config[:access_key_id],
      secret_access_key: config[:secret_access_key],
      region: region(config),
      service: "s3",
      datetime: DateTime.utc_now(),
      method: :get,
      url: object_url(key),
      expires: expires_in
    )
    |> URI.to_string()
  end

  defp request(options) do
    config = config()

    [
      aws_sigv4: [
        access_key_id: config[:access_key_id],
        secret_access_key: config[:secret_access_key],
        region: region(config),
        service: :s3
      ],
      retry: :transient,
      max_retries: 2
    ]
    |> Keyword.merge(Application.get_env(:phantom, :s3_req_options, []))
    |> Keyword.merge(options)
    |> Req.request()
  end

  defp ok({:ok, %Req.Response{status: status}}) when status in 200..299, do: :ok

  defp ok({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, "S3 answered #{status}#{error_code(body)}"}

  defp ok({:error, exception}), do: {:error, Exception.message(exception)}

  # S3 errors are XML: <Error><Code>AccessDenied</Code>...
  defp error_code(body) when is_binary(body) do
    case Regex.run(~r{<Code>([^<]+)</Code>}, body) do
      [_, code] -> ": #{code}"
      nil -> ""
    end
  end

  defp error_code(_body), do: ""

  defp object_url(key) do
    config = config()
    endpoint = String.trim_trailing(config[:endpoint], "/")
    path = URI.encode(key, &(&1 == ?/ or URI.char_unreserved?(&1)))
    "#{endpoint}/#{config[:bucket]}/#{path}"
  end

  defp region(config), do: config[:region] || "auto"

  defp config, do: Application.get_env(:phantom, __MODULE__, [])
end
