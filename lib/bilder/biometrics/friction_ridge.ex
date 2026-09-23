defmodule Bilder.Biometrics.FrictionRidge do
  @moduledoc """
  HTTP client for the synthetic friction-ridge service (`python_biometrics/`),
  which generates rolled fingerprints, slaps, palmprints and tenprint cards
  procedurally on the CPU.
  """

  @doc "Returns `:ready`, `{:error, reason}` or `:unreachable`."
  def health do
    case Req.get(request(), url: "/health") do
      {:ok, %Req.Response{status: 200, body: %{"status" => "ready"}}} -> :ready
      {:ok, %Req.Response{status: status}} -> {:error, "unexpected response (HTTP #{status})"}
      {:error, _exception} -> :unreachable
    end
  end

  @doc """
  Renders one image. `kind` is `"finger"` (code 1-10), `"slap"` (13-15),
  `"palm"` (21-24) or `"card"`; `seed` identifies the synthetic person and
  `capture` (0, 1, ...) a separate capture of them.

  Returns `{:ok, %{image: png, width:, height:, ppi:, generator:, meta:}}` or
  `{:error, message}`.
  """
  def render(kind, code, seed, capture, opts \\ []) do
    body = %{
      kind: kind,
      code: code,
      seed: seed,
      capture: capture,
      label: Keyword.get(opts, :label, "")
    }

    case Req.post(request(), url: "/render", json: body) do
      {:ok, %Req.Response{status: 200, body: %{"image" => image} = response}} ->
        {:ok,
         %{
           image: Base.decode64!(image),
           width: response["width"],
           height: response["height"],
           ppi: response["ppi"],
           generator: response["generator"],
           meta: response["meta"] || %{}
         }}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "Friction-ridge rendering failed (HTTP #{status}): #{inspect(body)}"}

      {:error, %{reason: :econnrefused}} ->
        {:error,
         "Couldn't reach the friction-ridge service at #{base_url()}. " <>
           "Make sure `python_biometrics/server.py` is running."}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp request do
    extra_opts = Application.get_env(:bilder, :biometrics_req_options, [])

    Req.new(
      [base_url: base_url(), receive_timeout: :timer.minutes(5), retry: false] ++ extra_opts
    )
  end

  defp base_url, do: Application.fetch_env!(:bilder, :biometrics_service_url)
end
