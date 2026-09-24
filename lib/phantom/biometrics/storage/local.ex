defmodule Phantom.Biometrics.Storage.Local do
  @moduledoc """
  Stores images as plain files under `root/0`
  (`config :phantom, :biometrics_output_dir`).
  """

  @behaviour Phantom.Biometrics.Storage

  @doc "The folder files are stored in."
  def root, do: Application.get_env(:phantom, :biometrics_output_dir, "data/synthetic/biometrics")

  @impl true
  def put(key, data) do
    with {:ok, path} <- path(key),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, data)
    else
      :error -> {:error, :invalid_key}
      error -> error
    end
  end

  @impl true
  def read(key) do
    case path(key) do
      {:ok, path} -> File.read(path)
      :error -> {:error, :invalid_key}
    end
  end

  @impl true
  def exists?(key) do
    case path(key) do
      {:ok, path} -> File.regular?(path)
      :error -> false
    end
  end

  @impl true
  def local_path(key) do
    with {:ok, path} <- path(key), true <- File.regular?(path) do
      {:ok, path}
    else
      _ -> :error
    end
  end

  # Keys are relative paths that must stay inside the root.
  defp path(key) do
    case Path.safe_relative(key) do
      {:ok, relative} -> {:ok, Path.join(root(), relative)}
      :error -> :error
    end
  end
end
