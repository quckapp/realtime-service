defmodule QuckAppRealtimeWeb.ApiSpec do
  @moduledoc """
  OpenAPI specification for the Realtime Service API.
  """
  alias OpenApiSpex.{Info, OpenApi, Paths, Server, Components, SecurityScheme}
  alias QuckAppRealtimeWeb.{Endpoint, Router}
  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Realtime Service API",
        description: "Real-time communication, presence, and signaling API",
        version: "1.0.0",
        contact: %OpenApiSpex.Contact{
          name: "QuckApp Team",
          email: "support@quckapp.com"
        },
        license: %OpenApiSpex.License{
          name: "Proprietary"
        }
      },
      servers: [
        %Server{url: "/", description: "Current server"},
        %Server{url: "http://localhost:4003", description: "Local development"},
        %Server{url: "https://realtime.quckapp.com", description: "Production"}
      ],
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            bearerFormat: "JWT",
            description: "JWT authentication token"
          },
          "apiKey" => %SecurityScheme{
            type: "apiKey",
            name: "X-API-Key",
            in: "header",
            description: "API key for service-to-service communication"
          }
        }
      },
      security: [
        %{"bearerAuth" => []}
      ],
      tags: [
        %OpenApiSpex.Tag{
          name: "Health",
          description: "Health check and liveness endpoints"
        },
        %OpenApiSpex.Tag{
          name: "Metrics",
          description: "Prometheus metrics endpoint"
        },
        %OpenApiSpex.Tag{
          name: "Calls",
          description: "Call management operations"
        },
        %OpenApiSpex.Tag{
          name: "Recordings",
          description: "Call recording management"
        },
        %OpenApiSpex.Tag{
          name: "Huddles",
          description: "Huddle (quick audio meeting) management"
        },
        %OpenApiSpex.Tag{
          name: "Presence",
          description: "User presence and typing indicators"
        },
        %OpenApiSpex.Tag{
          name: "Devices",
          description: "Device and push notification token management"
        },
        %OpenApiSpex.Tag{
          name: "Signaling",
          description: "WebRTC signaling and ICE server configuration"
        }
      ]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
