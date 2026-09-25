defmodule Phantom.Biometrics.SharesConfigTest do
  # Changes the application env, so not async.
  use Phantom.DataCase, async: false

  import Phantom.BiometricsFixtures

  alias Phantom.Biometrics

  test "sharing is off without a bucket" do
    run = create_run(subjects: 1, shots: ["mugshot_left_profile"])
    {:ok, subject} = Biometrics.get_subject(run, "subject_001")
    config = Application.fetch_env!(:phantom, Phantom.S3)
    Application.put_env(:phantom, Phantom.S3, Keyword.put(config, :bucket, nil))
    on_exit(fn -> Application.put_env(:phantom, Phantom.S3, config) end)

    refute Biometrics.sharing_enabled?()
    assert {:error, :not_configured} = Biometrics.share_subject(subject, "zip", %{})
  end
end
