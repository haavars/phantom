# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :phantom,
  ecto_repos: [Phantom.Repo],
  generators: [timestamp_type: :utc_datetime]

# Base URL of the local Qwen-Image-2.1 inference service (see python_inference/).
# Overridable at runtime via the QWEN_SERVICE_URL env var, see config/runtime.exs.
config :phantom, :qwen_service_url, "http://localhost:8000"

# The Phoenix app supervises python_inference/server.py directly (see
# Phantom.QwenService) so it starts and stops along with `mix phx.server`.
# Disable with QWEN_AUTOSTART=false and override the directory with
# QWEN_SERVICE_DIR, see config/runtime.exs.
config :phantom, :start_qwen_service, true
config :phantom, :qwen_service_dir, Path.expand("../python_inference", __DIR__)

# Base URL of the synthetic friction-ridge service (see python_biometrics/), which
# the app also starts and stops itself. Overridable with BIOMETRICS_SERVICE_URL,
# BIOMETRICS_AUTOSTART=false and BIOMETRICS_SERVICE_DIR, see config/runtime.exs.
config :phantom, :biometrics_service_url, "http://localhost:8001"
config :phantom, :start_biometrics_service, true
config :phantom, :biometrics_service_dir, Path.expand("../python_biometrics", __DIR__)

# Where Phantom.Biometrics.Harness writes synthetic face runs (and where the
# /biometrics pages read them from). Gitignored.
config :phantom, :biometrics_output_dir, Path.expand("../data/synthetic/biometrics", __DIR__)

# Configure the endpoint
config :phantom, PhantomWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PhantomWeb.ErrorHTML, json: PhantomWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Phantom.PubSub,
  live_view: [signing_salt: "Pr9RgkLp"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :phantom, Phantom.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  phantom: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  phantom: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
