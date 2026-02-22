import Config

# =============================================================================
# Runtime Configuration for QuckChat Realtime Service
# =============================================================================
# This file is executed at runtime (not compile time)
# All environment variable reads happen here for Docker/production deployments

if config_env() == :prod do
  # ========================================
  # MySQL Database Configuration (Optional)
  # (Store-and-forward queue for offline messages)
  # ========================================
  if database_url = System.get_env("DATABASE_URL") do
    config :quckapp_realtime, QuckAppRealtime.Repo,
      url: database_url,
      pool_size: String.to_integer(System.get_env("DATABASE_POOL_SIZE") || "20"),
      ssl: System.get_env("DATABASE_SSL", "false") == "true",
      socket_options: if(System.get_env("DATABASE_IPV6") == "true", do: [:inet6], else: [])
  else
    # Disable Ecto repo when DATABASE_URL is not provided
    config :quckapp_realtime, QuckAppRealtime.Repo,
      pool_size: 0
  end

  # ========================================
  # MongoDB Configuration
  # (Main document store)
  # ========================================
  mongodb_url = System.get_env("MONGODB_URL") || "mongodb://localhost:27017/quckapp"

  config :quckapp_realtime, QuckAppRealtime.Mongo,
    url: mongodb_url,
    pool_size: String.to_integer(System.get_env("MONGODB_POOL_SIZE") || "10"),
    ssl: System.get_env("MONGODB_SSL", "false") == "true"

  # ========================================
  # Phoenix Endpoint Configuration
  # ========================================
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("HOST") || "0.0.0.0"
  port = String.to_integer(System.get_env("PORT") || "4003")

  config :quckapp_realtime, QuckAppRealtimeWeb.Endpoint,
    url: [host: System.get_env("EXTERNAL_HOST") || host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base,
    server: true

  # ========================================
  # Redis Configuration
  # (Distributed state and PubSub)
  # ========================================
  redis_host = System.get_env("REDIS_HOST") || "localhost"
  redis_port = String.to_integer(System.get_env("REDIS_PORT") || "6379")
  redis_password = System.get_env("REDIS_PASSWORD")

  config :quckapp_realtime, :redis,
    host: redis_host,
    port: redis_port,
    password: redis_password,
    ssl: System.get_env("REDIS_SSL", "false") == "true"

  # ========================================
  # Kafka Configuration
  # (Event streaming)
  # ========================================
  kafka_enabled = System.get_env("KAFKA_ENABLED", "true") == "true"

  if kafka_enabled do
    kafka_brokers =
      System.get_env("KAFKA_BROKERS", "localhost:9092")
      |> String.split(",")
      |> Enum.map(fn broker ->
        [host, port] = String.split(broker, ":")
        {String.to_charlist(host), String.to_integer(port)}
      end)

    config :quckapp_realtime, :kafka,
      enabled: true,
      brokers: kafka_brokers,
      consumer_group: System.get_env("KAFKA_CONSUMER_GROUP") || "realtime-service-group",
      topics: %{
        messages: System.get_env("KAFKA_TOPIC_MESSAGES") || "quckapp.messages",
        presence: System.get_env("KAFKA_TOPIC_PRESENCE") || "quckapp.presence",
        notifications: System.get_env("KAFKA_TOPIC_NOTIFICATIONS") || "quckapp.notifications",
        events: System.get_env("KAFKA_TOPIC_EVENTS") || "quckapp.events"
      }

    config :brod,
      clients: [
        kafka_client: [
          endpoints: kafka_brokers,
          auto_start_producers: true,
          default_producer_config: [
            required_acks: 1,
            partition_buffer_limit: 512
          ]
        ]
      ]

    # KafkaEx configuration - needs brokers as {host_string, port} tuples
    kafka_ex_brokers =
      System.get_env("KAFKA_BROKERS", "localhost:9092")
      |> String.split(",")
      |> Enum.map(fn broker ->
        [host, port] = String.split(broker, ":")
        {host, String.to_integer(port)}
      end)

    config :kafka_ex,
      brokers: kafka_ex_brokers,
      consumer_group: System.get_env("KAFKA_CONSUMER_GROUP") || "realtime-service-group",
      disable_default_worker: false,
      sync_timeout: 3000,
      max_restarts: 10,
      max_seconds: 60,
      use_ssl: false,
      kafka_version: "kayrock"
  else
    config :quckapp_realtime, :kafka, enabled: false
    # Disable KafkaEx when Kafka is not enabled
    config :kafka_ex,
      disable_default_worker: true
  end

  # ========================================
  # Auth Service Integration
  # ========================================
  auth_service_url = System.get_env("AUTH_SERVICE_URL") || "http://localhost:8081"

  config :quckapp_realtime, :auth_service,
    url: auth_service_url,
    api_key: System.get_env("AUTH_SERVICE_API_KEY"),
    timeout: String.to_integer(System.get_env("AUTH_SERVICE_TIMEOUT") || "5000")

  # ========================================
  # Backend Gateway Integration
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

  # Get issuer from environment or use default
  # Set verify_issuer: false when tokens come from external service (Spring auth)
  jwt_issuer = System.get_env("JWT_ISSUER") || "quckapp-auth-local"

  config :quckapp_realtime, QuckAppRealtime.Guardian,
    issuer: jwt_issuer,
    secret_key: jwt_secret,
    ttl: {1, :hour},
    # Disable issuer verification - tokens come from Spring auth-service
    verify_issuer: false,
    allowed_algos: ["HS256", "HS384", "HS512"]

  # ========================================
  # WebRTC / ICE Servers Configuration
  # ========================================
  config :quckapp_realtime, :ice_servers,
    stun: System.get_env("STUN_SERVER_URL") || "stun:stun.l.google.com:19302",
    turn_url: System.get_env("TURN_SERVER_URL"),
    turn_username: System.get_env("TURN_USERNAME"),
    credential: System.get_env("TURN_CREDENTIAL")

  # ========================================
  # Erlang Clustering Configuration
  # ========================================
  node_name = System.get_env("NODE_NAME")

  if node_name do
    config :quckapp_realtime, :node_name, String.to_atom(node_name)
  end

  cluster_nodes =
    case System.get_env("CLUSTER_NODES") do
      nil -> []
      "" -> []
      nodes -> String.split(nodes, ",") |> Enum.map(&String.to_atom/1)
    end

  config :quckapp_realtime, :cluster_nodes, cluster_nodes
  config :quckapp_realtime, :cluster_dns, System.get_env("CLUSTER_DNS")

  # Release cookie for distributed Erlang
  if cookie = System.get_env("RELEASE_COOKIE") do
    config :quckapp_realtime, :release_cookie, String.to_atom(cookie)
  end

  # ========================================
  # Firebase Push Notifications
  # ========================================
  config :quckapp_realtime, :firebase,
    enabled: System.get_env("FIREBASE_ENABLED", "false") == "true",
    project_id: System.get_env("FIREBASE_PROJECT_ID"),
    service_account: System.get_env("FIREBASE_SERVICE_ACCOUNT")

  # ========================================
  # Telemetry & Metrics
  # ========================================
  config :quckapp_realtime, :telemetry,
    enabled: System.get_env("TELEMETRY_ENABLED", "true") == "true",
    metrics_port: String.to_integer(System.get_env("METRICS_PORT") || "9568")

  # ========================================
  # Logging Configuration
  # ========================================
  log_level =
    case System.get_env("LOG_LEVEL", "info") do
      "debug" -> :debug
      "info" -> :info
      "warning" -> :warning
      "warn" -> :warning
      "error" -> :error
      _ -> :info
    end

  config :logger, level: log_level

  config :logger, :console,
    format: "$time $metadata[$level] $message\n",
    metadata: [:request_id, :user_id, :channel]
end
