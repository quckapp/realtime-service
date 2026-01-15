import Config

# Production endpoint configuration
config :quckapp_realtime, QuckAppRealtimeWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: {:system, "PORT"}],
  url: [host: {:system, "HOST"}, port: 443, scheme: "https"],
  check_origin: {:system, "ALLOWED_ORIGINS"},
  secret_key_base: {:system, "SECRET_KEY_BASE"},
  server: true

# ========================================
# MySQL Database (WhatsApp-style persistence)
# ========================================
config :quckapp_realtime, QuckAppRealtime.Repo,
  url: {:system, "DATABASE_URL"},
  pool_size: {:system, "DATABASE_POOL_SIZE", 20},
  ssl: true,
  ssl_opts: [verify: :verify_peer]

# MongoDB configuration (legacy - for NestJS integration)
config :quckapp_realtime, QuckAppRealtime.Mongo,
  url: {:system, "MONGODB_URL"},
  pool_size: {:system, "MONGODB_POOL_SIZE", 20},
  ssl: true

# Redis configuration with sentinel support
config :quckapp_realtime, :redis,
  url: {:system, "REDIS_URL"},
  ssl: {:system, "REDIS_SSL", false}

# Redis PubSub for clustering
config :quckapp_realtime, QuckAppRealtime.PubSub,
  adapter: Phoenix.PubSub.Redis,
  url: {:system, "REDIS_URL"},
  node_name: {:system, "NODE_NAME"}

# ========================================
# Erlang Clustering (Production)
# ========================================
config :quckapp_realtime, :cluster_nodes, {:system, "CLUSTER_NODES"}
config :quckapp_realtime, :cluster_dns, {:system, "CLUSTER_DNS"}

# Guardian JWT
config :quckapp_realtime, QuckAppRealtime.Guardian,
  issuer: "quckapp_realtime",
  secret_key: {:system, "JWT_SECRET"}

# TURN/STUN servers
config :quckapp_realtime, :ice_servers,
  stun: {:system, "STUN_SERVER_URL", "stun:stun.l.google.com:19302"},
  turn_url: {:system, "TURN_SERVER_URL"},
  turn_username: {:system, "TURN_USERNAME"},
  turn_credential: {:system, "TURN_CREDENTIAL"}

# NestJS Backend URL
config :quckapp_realtime, :backend_url, {:system, "BACKEND_URL"}

# Firebase for push notifications
config :quckapp_realtime, :firebase,
  project_id: {:system, "FIREBASE_PROJECT_ID"},
  service_account: {:system, "FIREBASE_SERVICE_ACCOUNT"}

# Logger level
config :logger, level: :info
