# =============================================================================
# LOCAL (Mock) Environment Configuration
# =============================================================================
# Use this profile for local development with Docker containers
# Run with: MIX_ENV=local mix phx.server
# =============================================================================

import Config

config :quckapp_realtime, QuckAppRealtimeWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4001],
  check_origin: false,
  debug_errors: true,
  code_reloader: false,
  secret_key_base: "local_dev_secret_key_base_realtime_service_quckapp_32_chars"

# PostgreSQL - Local Docker
config :quckapp_realtime, QuckAppRealtime.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "quckapp_realtime_local",
  pool_size: 10,
  show_sensitive_data_on_connection_error: true

# MongoDB - Local Docker
config :quckapp_realtime, QuckAppRealtime.Mongo,
  url: "mongodb://localhost:27017/quckapp_realtime_local",
  pool_size: 5

# Redis - Local Docker
config :quckapp_realtime, :redis,
  host: "localhost",
  port: 6379,
  password: nil,
  database: 0

# Phoenix PubSub with Redis - Local Docker
config :quckapp_realtime, QuckAppRealtime.PubSub,
  adapter: Phoenix.PubSub.Redis,
  host: "localhost",
  port: 6379,
  node_name: "realtime-local"

# Kafka - Local Docker
config :quckapp_realtime, :kafka,
  enabled: true,
  brokers: [{"localhost", 9092}],
  consumer_group: "realtime-service-local"

# JWT - Same secret as auth-service local
config :quckapp_realtime, QuckAppRealtime.Guardian,
  issuer: "quckapp-auth-local",
  secret_key: "bG9jYWwtZGV2LXNlY3JldC1rZXktZm9yLXRlc3Rpbmctb25seS0zMi1jaGFycw=="

# Erlang Clustering (disabled for local)
config :quckapp_realtime, :cluster_nodes, []
config :quckapp_realtime, :cluster_dns, nil

# TURN/STUN servers - Only STUN for local
config :quckapp_realtime, :ice_servers,
  stun: "stun:stun.l.google.com:19302",
  turn_url: nil,
  turn_username: nil,
  turn_credential: nil

# Services
config :quckapp_realtime, :services,
  auth_service_url: "http://localhost:8081",
  user_service_url: "http://localhost:8082",
  nestjs_url: "http://localhost:3000"

# NestJS Backend
config :quckapp_realtime, :nestjs_url, "http://localhost:3000"
config :quckapp_realtime, :nestjs_api_key, nil

# Firebase (disabled for local)
config :quckapp_realtime, :firebase,
  project_id: nil,
  service_account: nil

# Logging - Verbose for local
config :logger, :console,
  format: "[$level] $message\n",
  level: :debug

# Phoenix live dashboard
config :quckapp_realtime, dev_routes: true
