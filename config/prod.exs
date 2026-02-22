import Config

# =============================================================================
# Production Configuration
# =============================================================================
# Note: Most production configuration has moved to runtime.exs for proper
# environment variable handling. The {:system, "VAR"} syntax is deprecated.
#
# See config/runtime.exs for:
# - Endpoint configuration
# - Database (MySQL/Ecto Repo)
# - MongoDB
# - Redis
# - Kafka
# - JWT/Guardian
# - Clustering
# =============================================================================

# Logger level for production
config :logger, level: :info
