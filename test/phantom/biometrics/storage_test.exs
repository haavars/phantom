defmodule Phantom.Biometrics.StorageTest do
  use ExUnit.Case, async: true

  alias Phantom.Biometrics.Storage

  test "stores files by key and reports their size and checksum" do
    key = "storage-#{System.unique_integer([:positive])}/subject_001/shot.png"

    assert {:ok, %{storage_key: ^key, byte_size: 5, sha256: sha256}} = Storage.put(key, "hello")
    assert sha256 == :crypto.hash(:sha256, "hello") |> Base.encode16(case: :lower)
    assert Storage.exists?(key)
    assert Storage.read(key) == {:ok, "hello"}
    assert {:ok, path} = Storage.local_path(key)
    assert File.read!(path) == "hello"
  end

  test "rejects keys that leave the storage root" do
    assert {:error, :invalid_key} = Storage.put("../escape.png", "x")
    assert {:error, :invalid_key} = Storage.read("/etc/passwd")
    refute Storage.exists?("../../mix.exs")
    assert Storage.local_path("../mix.exs") == :error
  end

  test "builds keys from run, subject and shot" do
    assert Storage.key("r1", "subject_002", "rolled_03") == "r1/subject_002/rolled_03.png"
  end
end
