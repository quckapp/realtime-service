defmodule QuckAppRealtimeWeb.Schemas.Common do
  @moduledoc """
  Common schemas used across the Realtime Service API.
  """
  alias OpenApiSpex.Schema

  defmodule SuccessResponse do
    @moduledoc "Generic success response"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SuccessResponse",
      description: "Generic success response",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean, description: "Indicates if the operation was successful"}
      },
      required: [:success],
      example: %{
        "success" => true
      }
    })
  end

  defmodule ErrorResponse do
    @moduledoc "Generic error response"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ErrorResponse",
      description: "Generic error response",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean, description: "Always false for errors"},
        error: %Schema{type: :string, description: "Error code"},
        message: %Schema{type: :string, description: "Human-readable error message"}
      },
      required: [:success, :error],
      example: %{
        "success" => false,
        "error" => "not_found",
        "message" => "Resource not found"
      }
    })
  end

  defmodule HealthResponse do
    @moduledoc "Health check response"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HealthResponse",
      description: "Health check response",
      type: :object,
      properties: %{
        status: %Schema{type: :string, description: "Service status"},
        service: %Schema{type: :string, description: "Service name"},
        version: %Schema{type: :string, description: "Service version"},
        timestamp: %Schema{type: :string, format: :"date-time", description: "Current timestamp"}
      },
      required: [:status, :service, :version, :timestamp],
      example: %{
        "status" => "ok",
        "service" => "quckapp-realtime",
        "version" => "1.0.0",
        "timestamp" => "2024-01-15T10:30:00Z"
      }
    })
  end

  defmodule ReadyResponse do
    @moduledoc "Readiness check response"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ReadyResponse",
      description: "Readiness check response with dependency status",
      type: :object,
      properties: %{
        ready: %Schema{type: :boolean, description: "Overall readiness status"},
        checks: %Schema{
          type: :object,
          description: "Individual dependency check results",
          properties: %{
            redis: %Schema{type: :boolean, description: "Redis connection status"},
            mongodb: %Schema{type: :boolean, description: "MongoDB connection status"}
          }
        }
      },
      required: [:ready, :checks],
      example: %{
        "ready" => true,
        "checks" => %{
          "redis" => true,
          "mongodb" => true
        }
      }
    })
  end

  defmodule LiveResponse do
    @moduledoc "Liveness check response"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "LiveResponse",
      description: "Liveness check response with runtime statistics",
      type: :object,
      properties: %{
        alive: %Schema{type: :boolean, description: "Service is alive"},
        stats: %Schema{
          type: :object,
          description: "Runtime statistics",
          properties: %{
            connected_users: %Schema{type: :integer, description: "Number of connected users"},
            active_calls: %Schema{type: :integer, description: "Number of active calls"},
            active_huddles: %Schema{type: :integer, description: "Number of active huddles"},
            memory_mb: %Schema{type: :number, format: :float, description: "Memory usage in MB"},
            uptime_seconds: %Schema{type: :integer, description: "Service uptime in seconds"}
          }
        }
      },
      required: [:alive, :stats],
      example: %{
        "alive" => true,
        "stats" => %{
          "connected_users" => 150,
          "active_calls" => 25,
          "active_huddles" => 10,
          "memory_mb" => 256.5,
          "uptime_seconds" => 86400
        }
      }
    })
  end

  defmodule PaginationParams do
    @moduledoc "Pagination parameters"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PaginationParams",
      description: "Pagination parameters",
      type: :object,
      properties: %{
        limit: %Schema{type: :integer, minimum: 1, maximum: 100, default: 20, description: "Number of items to return"},
        offset: %Schema{type: :integer, minimum: 0, default: 0, description: "Number of items to skip"}
      }
    })
  end
end
