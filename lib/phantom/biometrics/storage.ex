defmodule Phantom.Biometrics.Storage do
  @moduledoc """
  Where image files live. The database only stores a storage key per image
  (`<run>/<subject>/<shot>.png`), so the backend can change without touching
  the data: set `config :phantom, :biometrics_storage` to another module that
  implements this behaviour. The default is `Phantom.Biometrics.Storage.Local`.
  """

  @doc "Stores `data` under `key`, replacing what was there."
  @callback put(key :: String.t(), data :: binary()) :: :ok | {:error, term()}

  @doc "Reads the data stored under `key`."
  @callback read(key :: String.t()) :: {:ok, binary()} | {:error, term()}

  @doc "True when something is stored under `key`."
  @callback exists?(key :: String.t()) :: boolean()

  @doc "A local file path for `key`, for backends that have one (to send the file directly)."
  @callback local_path(key :: String.t()) :: {:ok, Path.t()} | :error

  @doc """
  Stores `data` under `key`. Returns `{:ok, %{storage_key:, byte_size:, sha256:}}`,
  the fields an `Phantom.Biometrics.Image` keeps about its file.
  """
  def put(key, data) do
    with :ok <- adapter().put(key, data) do
      {:ok,
       %{
         storage_key: key,
         byte_size: byte_size(data),
         sha256: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
       }}
    end
  end

  def read(key), do: adapter().read(key)
  def exists?(key), do: adapter().exists?(key)
  def local_path(key), do: adapter().local_path(key)

  @doc "The storage key of a shot's image: `<run>/<subject>/<shot>.png`."
  def key(run_name, subject_name, shot), do: Path.join([run_name, subject_name, shot <> ".png"])

  defp adapter, do: Application.get_env(:phantom, :biometrics_storage, __MODULE__.Local)
end
