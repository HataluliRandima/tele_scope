# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :demo_app,
  ecto_repos: [DemoApp.Repo],
  generators: [timestamp_type: :utc_datetime]

config :demo_app, Oban,
  engine: Oban.Engines.Lite,
  repo: DemoApp.Repo,
  queues: [default: 5],
  plugins: [Oban.Plugins.Pruner]

# Configure the endpoint
config :demo_app, DemoAppWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DemoAppWeb.ErrorHTML, json: DemoAppWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: DemoApp.PubSub,
  live_view: [signing_salt: "8XWEE1Uv"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
