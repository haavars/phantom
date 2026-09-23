import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :bilder, Bilder.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "bilder_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :bilder, BilderWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "LNB3YyH4k8NJAaHRrmgLrnSMmhK2my95KC6YrhNGfTH/Syzxbv14AEGgayZsYg2s",
  server: false

# In test we don't send emails
config :bilder, Bilder.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Stub the Qwen-Image-2.1 HTTP calls in tests instead of hitting a real service.
# See Bilder.ImageGeneration and Req.Test.
config :bilder, :qwen_image_req_options, plug: {Req.Test, Bilder.ImageGeneration}

# Don't spawn the real python_inference process during tests.
config :bilder, :start_qwen_service, false

# Tests that read face runs point this at a tmp_dir; this default keeps anything
# that slips through out of the real data folder.
config :bilder, :face_output_dir, Path.expand("../tmp/test/faces", __DIR__)
