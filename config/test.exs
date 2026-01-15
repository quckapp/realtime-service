import Config

# Test endpoint configuration
config :quckapp_realtime, QuckAppRealtimeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_for_testing_only_change_in_production",
  server: false

# MySQL test configuration
config :quckapp_realtime, QuckAppRealtime.Repo,
  username: "root",
  password: "",
  hostname: "localhost",
  database: "quckapp_realtime_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# MongoDB test configuration
config :quckapp_realtime, QuckAppRealtime.Mongo,
  url: "mongodb://localhost:27017/quckapp_test",
  pool_size: 5

# Redis test configuration
config :quckapp_realtime, :redis,
  host: "localhost",
  port: 6379,
  database: 1

# Erlang Clustering (disabled in tests)
config :quckapp_realtime, :cluster_nodes, []
config :quckapp_realtime, :cluster_dns, nil

# Guardian JWT
config :quckapp_realtime, QuckAppRealtime.Guardian,
  issuer: "quckapp_realtime",
  secret_key: "test_jwt_secret"

# Logger level
config :logger, level: :warning
