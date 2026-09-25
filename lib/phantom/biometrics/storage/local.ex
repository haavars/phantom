defmodule Phantom.Biometrics.Storage.Local do
  @moduledoc """
  Stores images as plain files under `root/0`
  (`config :phantom, :biometrics_output_dir`).
  """

  @behaviour Phantom.Biometrics.Storage

  @doc "The folder files are stored in."
  def root, do: Application.get_env(:phantom, :biometrics_output_dir, "data/synthetic/biometrics")

  # Written to a temporary file and renamed, so a reader never sees half a file
  # (two requests can make the same preview at once).
  @impl true
  def put(key, data) do
    with {:ok, path} <- path(key),
         :ok <- File.mkdir_p(Path.dirname(path)),
         temp = "#{path}.#{System.unique_integer([:positive])}.tmp",
         :ok <- File.write(temp, data),
         :ok <- rename(temp, path) do
      :ok
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
  def stream(key) do
    case local_path(key) do
      {:ok, path} -> {:ok, File.stream!(path, 64 * 1024)}
      :error -> {:error, :not_found}
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

  defp rename(temp, path) do
    with {:error, _} = error <- File.rename(temp, path) do
      File.rm(temp)
      error
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
