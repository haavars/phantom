ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Phantom.Repo, :manual)

# Tests store images under a shared folder (config/test.exs); start it empty.
File.rm_rf!(Application.fetch_env!(:phantom, :biometrics_output_dir))
