# =============================================================================
# LIVE Environment Configuration
# =============================================================================
# Use this profile for live environment (same as production with stricter settings)
# Run with: MIX_ENV=live mix phx.server
# =============================================================================

import Config

config :quckapp_realtime, QuckAppRealtimeWeb.Endpoint,
  http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT") || "4001")],
  url: [host: System.get_env("PHX_HOST") || "localhost", port: 443, scheme: "https"],
  secret_key_base: System.get_env("SECRET_KEY_BASE") || raise("SECRET_KEY_BASE missing"),
  server: true,
  cache_static_manifest: "priv/static/cache_manifest.json"

# PostgreSQL - Live (highest pool size)
config :quckapp_realtime, QuckAppRealtime.Repo,
  url: System.get_env("DATABASE_URL") || raise("DATABASE_URL missing"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "100"),
  timeout: 15_000,
  connect_timeout: 10_000,
  ssl: System.get_env("DATABASE_SSL") == "true"

# MongoDB - Live (highest pool size)
config :quckapp_realtime, QuckAppRealtime.Mongo,
  url: System.get_env("MONGODB_URL") || raise("MONGODB_URL missing"),
  pool_size: String.to_integer(System.get_env("MONGODB_POOL_SIZE") || "100"),
  ssl: String.contains?(System.get_env("MONGODB_URL") || "", "mongodb+srv"),
  timeout: 15_000,
  connect_timeout: 10_000

# Redis - Live (highest pool size)
config :quckapp_realtime, :redis,
  host: System.get_env("REDIS_HOST") || raise("REDIS_HOST missing"),
  port: String.to_integer(System.get_env("REDIS_PORT") || "6379"),
  password: System.get_env("REDIS_PASSWORD"),
  database: String.to_integer(System.get_env("REDIS_DATABASE") || "0"),
  pool_size: 64,
  ssl: System.get_env("REDIS_SSL") == "true"

# Phoenix PubSub with Redis - Live
config :quckapp_realtime, QuckAppRealtime.PubSub,
  adapter: Phoenix.PubSub.Redis,
  host: System.get_env("REDIS_HOST") || raise("REDIS_HOST missing"),
  port: String.to_integer(System.get_env("REDIS_PORT") || "6379"),
  password: System.get_env("REDIS_PASSWORD"),
  ssl: System.get_env("REDIS_SSL") == "true",
  node_name: System.get_env("NODE_NAME") || "realtime-live"

# Kafka - Live
config :quckapp_realtime, :kafka,
  enabled: System.get_env("KAFKA_ENABLED", "true") == "true",
  brokers: String.split(System.get_env("KAFKA_BROKERS") || "localhost:9092", ","),
  consumer_group: "realtime-service-live",
  ssl: System.get_env("KAFKA_SSL") == "true"

# JWT
config :quckapp_realtime, QuckAppRealtime.Guardian,
  issuer: "quckapp-auth",
  secret_key: System.get_env("JWT_SECRET") || raise("JWT_SECRET missing")

# Erlang Clustering
config :quckapp_realtime, :cluster_nodes, []
config :quckapp_realtime, :cluster_dns, System.get_env("CLUSTER_DNS")

# TURN/STUN servers - Full TURN configuration for NAT traversal
config :quckapp_realtime, :ice_servers,
  stun: "stun:stun.l.google.com:19302",
  turn_url: System.get_env("TURN_SERVER_URL") || raise("TURN_SERVER_URL missing"),
  turn_username: System.get_env("TURN_USERNAME"),
  turn_credential: System.get_env("TURN_CREDENTIAL")

# Services
config :quckapp_realtime, :services,
  auth_service_url: System.get_env("AUTH_SERVICE_URL") || raise("AUTH_SERVICE_URL missing"),
  user_service_url: System.get_env("USER_SERVICE_URL") || raise("USER_SERVICE_URL missing"),
  nestjs_url: System.get_env("NESTJS_URL") || raise("NESTJS_URL missing")

# NestJS Backend
config :quckapp_realtime, :nestjs_url, System.get_env("NESTJS_URL") || raise("NESTJS_URL missing")
config :quckapp_realtime, :nestjs_api_key, System.get_env("NESTJS_API_KEY")

# Firebase
config :quckapp_realtime, :firebase,
  project_id: System.get_env("FIREBASE_PROJECT_ID"),
  service_account: System.get_env("FIREBASE_SERVICE_ACCOUNT")

# Logging - Error level only for live
config :logger, level: :error
