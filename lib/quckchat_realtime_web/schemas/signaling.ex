defmodule QuckAppRealtimeWeb.Schemas.Signaling do
  @moduledoc """
  Schemas for WebRTC signaling API operations.
  """
  alias OpenApiSpex.Schema

  defmodule IceConfigResponse do
    @moduledoc "Response for ICE configuration"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "IceConfigResponse",
      description: "Response containing full ICE configuration for WebRTC",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        config: %Schema{
          type: :object,
          description: "ICE configuration",
          properties: %{
            iceServers: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                properties: %{
                  urls: %Schema{
                    oneOf: [
                      %Schema{type: :string},
                      %Schema{type: :array, items: %Schema{type: :string}}
                    ],
                    description: "STUN/TURN server URL(s)"
                  },
                  username: %Schema{type: :string, description: "Username for TURN authentication"},
                  credential: %Schema{type: :string, description: "Credential for TURN authentication"}
                }
              },
              description: "List of ICE servers"
            },
            iceTransportPolicy: %Schema{
              type: :string,
              enum: ["all", "relay"],
              description: "ICE transport policy"
            },
            bundlePolicy: %Schema{
              type: :string,
              enum: ["balanced", "max-compat", "max-bundle"],
              description: "Bundle policy"
            },
            rtcpMuxPolicy: %Schema{
              type: :string,
              enum: ["require", "negotiate"],
              description: "RTCP mux policy"
            }
          }
        }
      },
      required: [:success, :config],
      example: %{
        "success" => true,
        "config" => %{
          "iceServers" => [
            %{
              "urls" => ["stun:stun.quckapp.com:3478"]
            },
            %{
              "urls" => ["turn:turn.quckapp.com:3478", "turn:turn.quckapp.com:443?transport=tcp"],
              "username" => "1705320600:user_123",
              "credential" => "abc123..."
            }
          ],
          "iceTransportPolicy" => "all",
          "bundlePolicy" => "max-bundle",
          "rtcpMuxPolicy" => "require"
        }
      }
    })
  end

  defmodule TurnCredentialsRequest do
    @moduledoc "Request for TURN credentials"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TurnCredentialsRequest",
      description: "Request for time-limited TURN credentials",
      type: :object,
      properties: %{
        ttl: %Schema{
          type: :integer,
          minimum: 3600,
          maximum: 86400,
          default: 86400,
          description: "Credential time-to-live in seconds"
        },
        region: %Schema{
          type: :string,
          description: "Preferred TURN server region"
        }
      },
      example: %{
        "ttl" => 86400,
        "region" => "us-east"
      }
    })
  end

  defmodule TurnCredentialsResponse do
    @moduledoc "Response containing TURN credentials"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TurnCredentialsResponse",
      description: "Response containing time-limited TURN credentials",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        credentials: %Schema{
          type: :object,
          properties: %{
            username: %Schema{type: :string, description: "TURN username (ephemeral)"},
            credential: %Schema{type: :string, description: "TURN credential (ephemeral)"},
            ttl: %Schema{type: :integer, description: "Credential time-to-live in seconds"},
            urls: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "TURN server URLs"
            }
          },
          required: [:username, :credential, :ttl, :urls]
        }
      },
      required: [:success, :credentials],
      example: %{
        "success" => true,
        "credentials" => %{
          "username" => "1705320600:user_123",
          "credential" => "hmac_sha1_signature_base64",
          "ttl" => 86400,
          "urls" => [
            "turn:turn.quckapp.com:3478",
            "turn:turn.quckapp.com:443?transport=tcp",
            "turns:turn.quckapp.com:443"
          ]
        }
      }
    })
  end
end
