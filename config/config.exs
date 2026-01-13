# General application configuration
import Config

config :quckchat_realtime,
  ecto_repos: [QuckChatRealtime.Repo],
  generators: [timestamp_type: :utc_datetime]

# Endpoint configuration
config :quckchat_realtime, QuckChatRealtimeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [json: QuckChatRealtimeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: QuckChatRealtime.PubSub,
  live_view: [signing_salt: "quckchat_realtime"]

# Guardian JWT configuration
config :quckchat_realtime, QuckChatRealtime.Guardian,
  issuer: "quckchat_realtime",
  secret_key: {:system, "JWT_SECRET"}

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :user_id, :channel]

# JSON library
config :phoenix, :json_library, Jason

# Import environment specific config
import_config "#{config_env()}.exs"
