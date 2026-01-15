import Config

# Runtime configuration for production
# This file is executed at runtime (not compile time)

if config_env() == :prod do
  # ========================================
  # MySQL Database Configuration
  # ========================================
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: mysql://USER:PASS@HOST:PORT/DATABASE
      """

  config :quckapp_realtime, QuckAppRealtime.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("DATABASE_POOL_SIZE") || "20"),
    ssl: System.get_env("DATABASE_SSL", "true") == "true"

  # ========================================
  # Phoenix Endpoint
  # ========================================
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :quckapp_realtime, QuckAppRealtimeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ========================================
  # Redis Configuration
  # ========================================
  redis_url = System.get_env("REDIS_URL") || "redis://localhost:6379"

  config :quckapp_realtime, :redis,
    url: redis_url,
    ssl: System.get_env("REDIS_SSL", "false") == "true"

  # ========================================
  # NestJS Backend Integration
  # ========================================
  config :quckapp_realtime, :nestjs_url,
    System.get_env("NESTJS_URL") || "http://localhost:3000"

  config :quckapp_realtime, :nestjs_api_key,
    System.get_env("NESTJS_API_KEY")

  # ========================================
  # JWT Configuration
  # ========================================
  jwt_secret =
    System.get_env("JWT_SECRET") ||
      raise "environment variable JWT_SECRET is missing"

  config :quckapp_realtime, QuckAppRealtime.Guardian,
    issuer: "quckapp_realtime",
    secret_key: jwt_secret

  # ========================================
  # ICE Servers (WebRTC)
  # ========================================
  config :quckapp_realtime, :ice_servers,
    stun: System.get_env("STUN_SERVER_URL") || "stun:stun.l.google.com:19302",
    turn_url: System.get_env("TURN_SERVER_URL"),
    turn_username: System.get_env("TURN_USERNAME"),
    credential: System.get_env("TURN_CREDENTIAL")

  # ========================================
  # Erlang Clustering
  # ========================================
  cluster_nodes =
    case System.get_env("CLUSTER_NODES") do
      nil -> []
      nodes -> String.split(nodes, ",") |> Enum.map(&String.to_atom/1)
    end

  config :quckapp_realtime, :cluster_nodes, cluster_nodes
  config :quckapp_realtime, :cluster_dns, System.get_env("CLUSTER_DNS")

  # ========================================
  # Firebase Push Notifications
  # ========================================
  config :quckapp_realtime, :firebase,
    project_id: System.get_env("FIREBASE_PROJECT_ID"),
    service_account: System.get_env("FIREBASE_SERVICE_ACCOUNT")
end
