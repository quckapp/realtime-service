defmodule QuckAppRealtimeWeb.Schemas.Call do
  @moduledoc """
  Schemas for call-related API operations.
  """
  alias OpenApiSpex.Schema

  defmodule InviteRequest do
    @moduledoc "Request to invite participants to a call"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CallInviteRequest",
      description: "Request to invite participants to a call",
      type: :object,
      properties: %{
        user_ids: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "List of user IDs to invite"
        },
        call_type: %Schema{
          type: :string,
          enum: ["audio", "video"],
          description: "Type of call"
        },
        conversation_id: %Schema{type: :string, description: "Associated conversation ID"}
      },
      required: [:user_ids],
      example: %{
        "user_ids" => ["user_123", "user_456"],
        "call_type" => "video",
        "conversation_id" => "conv_789"
      }
    })
  end

  defmodule InviteResponse do
    @moduledoc "Response after sending call invitations"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CallInviteResponse",
      description: "Response after sending call invitations",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        invited: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "List of successfully invited user IDs"
        },
        failed: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "List of user IDs that failed to be invited"
        }
      },
      required: [:success, :invited],
      example: %{
        "success" => true,
        "invited" => ["user_123", "user_456"],
        "failed" => []
      }
    })
  end

  defmodule Participant do
    @moduledoc "Call participant information"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CallParticipant",
      description: "Call participant information",
      type: :object,
      properties: %{
        user_id: %Schema{type: :string, description: "User ID"},
        display_name: %Schema{type: :string, description: "Display name"},
        joined_at: %Schema{type: :string, format: :"date-time", description: "Time when user joined"},
        is_muted: %Schema{type: :boolean, description: "Whether audio is muted"},
        is_video_enabled: %Schema{type: :boolean, description: "Whether video is enabled"},
        is_screen_sharing: %Schema{type: :boolean, description: "Whether screen sharing is active"}
      },
      required: [:user_id, :joined_at],
      example: %{
        "user_id" => "user_123",
        "display_name" => "John Doe",
        "joined_at" => "2024-01-15T10:30:00Z",
        "is_muted" => false,
        "is_video_enabled" => true,
        "is_screen_sharing" => false
      }
    })
  end

  defmodule ParticipantsResponse do
    @moduledoc "Response containing call participants"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CallParticipantsResponse",
      description: "Response containing list of call participants",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        call_id: %Schema{type: :string, description: "Call ID"},
        participants: %Schema{
          type: :array,
          items: Participant,
          description: "List of participants"
        },
        count: %Schema{type: :integer, description: "Total number of participants"}
      },
      required: [:success, :call_id, :participants],
      example: %{
        "success" => true,
        "call_id" => "call_abc123",
        "participants" => [
          %{
            "user_id" => "user_123",
            "display_name" => "John Doe",
            "joined_at" => "2024-01-15T10:30:00Z",
            "is_muted" => false,
            "is_video_enabled" => true,
            "is_screen_sharing" => false
          }
        ],
        "count" => 1
      }
    })
  end

  defmodule IceServer do
    @moduledoc "ICE server configuration"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "IceServer",
      description: "ICE server configuration for WebRTC",
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
      },
      required: [:urls],
      example: %{
        "urls" => ["stun:stun.quckapp.com:3478"],
        "username" => "1705320600:user_123",
        "credential" => "abc123..."
      }
    })
  end

  defmodule IceServersResponse do
    @moduledoc "Response containing ICE server configuration"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "IceServersResponse",
      description: "Response containing ICE server configuration for WebRTC",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        ice_servers: %Schema{
          type: :array,
          items: IceServer,
          description: "List of ICE servers"
        },
        ttl: %Schema{type: :integer, description: "Time-to-live for credentials in seconds"}
      },
      required: [:success, :ice_servers],
      example: %{
        "success" => true,
        "ice_servers" => [
          %{"urls" => ["stun:stun.quckapp.com:3478"]},
          %{
            "urls" => ["turn:turn.quckapp.com:3478"],
            "username" => "1705320600:user_123",
            "credential" => "abc123..."
          }
        ],
        "ttl" => 86400
      }
    })
  end
end
