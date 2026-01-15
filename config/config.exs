# General application configuration
import Config

config :quckapp_realtime,
  ecto_repos: [QuckAppRealtime.Repo],
  generators: [timestamp_type: :utc_datetime]

# Endpoint configuration
config :quckapp_realtime, QuckAppRealtimeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [json: QuckAppRealtimeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: QuckAppRealtime.PubSub,
  live_view: [signing_salt: "quckapp_realtime"]

# Guardian JWT configuration
config :quckapp_realtime, QuckAppRealtime.Guardian,
  issuer: "quckapp_realtime",
  secret_key: {:system, "JWT_SECRET"}

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :user_id, :channel]

# JSON library
config :phoenix, :json_library, Jason

# Import environment specific config
import_config "#{config_env()}.exs"
