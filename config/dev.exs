import Config

# Development endpoint configuration
config :quckchat_realtime, QuckChatRealtimeWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev_secret_key_base_change_in_production_at_least_64_bytes_long_123456",
  watchers: []

# ========================================
# MySQL Database (WhatsApp-style persistence)
# ========================================
config :quckchat_realtime, QuckChatRealtime.Repo,
  username: "root",
  password: "",
  hostname: "localhost",
  database: "quckchat_realtime_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# ========================================
# MongoDB Atlas (Main Data Storage)
# ========================================
# Replace with your MongoDB Atlas connection string:
# mongodb+srv://username:password@cluster.xxxxx.mongodb.net/quckchat?retryWrites=true&w=majority
config :quckchat_realtime, QuckChatRealtime.Mongo,
  url: System.get_env("MONGODB_URL") || "mongodb://localhost:27017/quckchat_dev",
  pool_size: 10,
  ssl: String.contains?(System.get_env("MONGODB_URL") || "", "mongodb+srv")

# Redis configuration
config :quckchat_realtime, :redis,
  host: "localhost",
  port: 6379,
  database: 0

# ========================================
# Erlang Clustering (Development)
# ========================================
config :quckchat_realtime, :cluster_nodes, []
config :quckchat_realtime, :cluster_dns, nil

# ========================================
# Kafka Event Streaming
# ========================================
config :quckchat_realtime, :kafka,
  enabled: System.get_env("KAFKA_ENABLED", "false") == "true",
  brokers: [
    {System.get_env("KAFKA_HOST", "localhost"), String.to_integer(System.get_env("KAFKA_PORT", "9092"))}
  ]

# Guardian JWT
config :quckchat_realtime, QuckChatRealtime.Guardian,
  issuer: "quckchat_realtime",
  secret_key: "dev_jwt_secret_key_change_in_production"

# TURN/STUN servers
config :quckchat_realtime, :ice_servers,
  stun: "stun:stun.l.google.com:19302",
  turn_url: nil,
  turn_username: nil,
  turn_credential: nil

# NestJS Backend URL (for user/conversation data)
config :quckchat_realtime, :nestjs_url, "http://localhost:3000"
config :quckchat_realtime, :nestjs_api_key, nil  # Set in production

# Firebase for push notifications
config :quckchat_realtime, :firebase,
  project_id: nil,
  service_account: nil

# Logger level
config :logger, level: :debug

# Phoenix live dashboard
config :quckchat_realtime, dev_routes: true
