# =============================================================================
# UAT1 Environment Configuration
# =============================================================================
# Use this profile for UAT1 environment
# Run with: MIX_ENV=uat1 mix phx.server
# =============================================================================

import Config

config :quckapp_realtime, QuckAppRealtimeWeb.Endpoint,
  http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT") || "4001")],
  url: [host: System.get_env("PHX_HOST") || "localhost", port: 443, scheme: "https"],
  secret_key_base: System.get_env("SECRET_KEY_BASE"),
  server: true

# PostgreSQL - UAT1
config :quckapp_realtime, QuckAppRealtime.Repo,
  url: System.get_env("DATABASE_URL"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "15")

# MongoDB - UAT1
config :quckapp_realtime, QuckAppRealtime.Mongo,
  url: System.get_env("MONGODB_URL"),
  pool_size: String.to_integer(System.get_env("MONGODB_POOL_SIZE") || "10"),
  ssl: String.contains?(System.get_env("MONGODB_URL") || "", "mongodb+srv")

# Redis - UAT1
config :quckapp_realtime, :redis,
  host: System.get_env("REDIS_HOST"),
  port: String.to_integer(System.get_env("REDIS_PORT") || "6379"),
  password: System.get_env("REDIS_PASSWORD"),
  database: String.to_integer(System.get_env("REDIS_DATABASE") || "0")

# Phoenix PubSub with Redis - UAT1
config :quckapp_realtime, QuckAppRealtime.PubSub,
  adapter: Phoenix.PubSub.Redis,
  host: System.get_env("REDIS_HOST"),
  port: String.to_integer(System.get_env("REDIS_PORT") || "6379"),
  password: System.get_env("REDIS_PASSWORD"),
  node_name: System.get_env("NODE_NAME") || "realtime-uat1"

# Kafka - UAT1
config :quckapp_realtime, :kafka,
  enabled: System.get_env("KAFKA_ENABLED", "true") == "true",
  brokers: [System.get_env("KAFKA_BROKER") || "localhost:9092"],
  consumer_group: "realtime-service-uat1"

# JWT
config :quckapp_realtime, QuckAppRealtime.Guardian,
  issuer: "quckapp-auth",
  secret_key: System.get_env("JWT_SECRET")

# Erlang Clustering
config :quckapp_realtime, :cluster_nodes, []
config :quckapp_realtime, :cluster_dns, System.get_env("CLUSTER_DNS")

# TURN/STUN servers
config :quckapp_realtime, :ice_servers,
  stun: "stun:stun.l.google.com:19302",
  turn_url: System.get_env("TURN_SERVER_URL"),
  turn_username: System.get_env("TURN_USERNAME"),
  turn_credential: System.get_env("TURN_CREDENTIAL")

# Services
config :quckapp_realtime, :services,
  auth_service_url: System.get_env("AUTH_SERVICE_URL"),
  user_service_url: System.get_env("USER_SERVICE_URL"),
  nestjs_url: System.get_env("NESTJS_URL")

# NestJS Backend
config :quckapp_realtime, :nestjs_url, System.get_env("NESTJS_URL")
config :quckapp_realtime, :nestjs_api_key, System.get_env("NESTJS_API_KEY")

# Firebase
config :quckapp_realtime, :firebase,
  project_id: System.get_env("FIREBASE_PROJECT_ID"),
  service_account: System.get_env("FIREBASE_SERVICE_ACCOUNT")

# Logging
config :logger, level: :info
