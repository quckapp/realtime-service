defmodule QuckAppRealtimeWeb.Schemas.Huddle do
  @moduledoc """
  Schemas for huddle-related API operations.
  """
  alias OpenApiSpex.Schema

  defmodule CreateRequest do
    @moduledoc "Request to create a new huddle"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HuddleCreateRequest",
      description: "Request to create a new huddle",
      type: :object,
      properties: %{
        name: %Schema{type: :string, description: "Huddle name/title"},
        channel_id: %Schema{type: :string, description: "Associated channel ID"},
        workspace_id: %Schema{type: :string, description: "Workspace ID"},
        initial_participants: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Initial list of participant user IDs"
        },
        audio_only: %Schema{type: :boolean, default: true, description: "Whether huddle is audio-only"}
      },
      required: [:channel_id],
      example: %{
        "name" => "Quick sync",
        "channel_id" => "channel_123",
        "workspace_id" => "ws_456",
        "initial_participants" => ["user_789"],
        "audio_only" => true
      }
    })
  end

  defmodule CreateResponse do
    @moduledoc "Response after creating a huddle"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HuddleCreateResponse",
      description: "Response after creating a huddle",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        huddle: %Schema{
          type: :object,
          properties: %{
            huddle_id: %Schema{type: :string, description: "Unique huddle ID"},
            name: %Schema{type: :string, description: "Huddle name"},
            channel_id: %Schema{type: :string, description: "Associated channel ID"},
            created_by: %Schema{type: :string, description: "User ID of creator"},
            created_at: %Schema{type: :string, format: :"date-time", description: "Creation timestamp"},
            join_url: %Schema{type: :string, description: "URL to join the huddle"}
          }
        }
      },
      required: [:success, :huddle],
      example: %{
        "success" => true,
        "huddle" => %{
          "huddle_id" => "huddle_abc123",
          "name" => "Quick sync",
          "channel_id" => "channel_123",
          "created_by" => "user_456",
          "created_at" => "2024-01-15T10:30:00Z",
          "join_url" => "https://app.quckapp.com/huddle/abc123"
        }
      }
    })
  end

  defmodule HuddleDetails do
    @moduledoc "Huddle details"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HuddleDetails",
      description: "Detailed huddle information",
      type: :object,
      properties: %{
        huddle_id: %Schema{type: :string, description: "Unique huddle ID"},
        name: %Schema{type: :string, description: "Huddle name"},
        channel_id: %Schema{type: :string, description: "Associated channel ID"},
        workspace_id: %Schema{type: :string, description: "Workspace ID"},
        created_by: %Schema{type: :string, description: "User ID of creator"},
        created_at: %Schema{type: :string, format: :"date-time", description: "Creation timestamp"},
        status: %Schema{type: :string, enum: ["active", "ended"], description: "Huddle status"},
        participants: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              user_id: %Schema{type: :string},
              display_name: %Schema{type: :string},
              joined_at: %Schema{type: :string, format: :"date-time"},
              is_muted: %Schema{type: :boolean},
              is_speaking: %Schema{type: :boolean}
            }
          },
          description: "List of current participants"
        },
        participant_count: %Schema{type: :integer, description: "Number of participants"},
        audio_only: %Schema{type: :boolean, description: "Whether huddle is audio-only"}
      },
      required: [:huddle_id, :channel_id, :status],
      example: %{
        "huddle_id" => "huddle_abc123",
        "name" => "Quick sync",
        "channel_id" => "channel_123",
        "workspace_id" => "ws_456",
        "created_by" => "user_789",
        "created_at" => "2024-01-15T10:30:00Z",
        "status" => "active",
        "participants" => [
          %{
            "user_id" => "user_789",
            "display_name" => "John Doe",
            "joined_at" => "2024-01-15T10:30:00Z",
            "is_muted" => false,
            "is_speaking" => true
          }
        ],
        "participant_count" => 1,
        "audio_only" => true
      }
    })
  end

  defmodule ShowResponse do
    @moduledoc "Response for getting huddle details"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HuddleShowResponse",
      description: "Response containing huddle details",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        huddle: HuddleDetails
      },
      required: [:success, :huddle]
    })
  end

  defmodule InviteRequest do
    @moduledoc "Request to invite users to a huddle"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HuddleInviteRequest",
      description: "Request to invite users to a huddle",
      type: :object,
      properties: %{
        user_ids: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "List of user IDs to invite"
        }
      },
      required: [:user_ids],
      example: %{
        "user_ids" => ["user_123", "user_456"]
      }
    })
  end

  defmodule InviteResponse do
    @moduledoc "Response after sending huddle invitations"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HuddleInviteResponse",
      description: "Response after sending huddle invitations",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        invited: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Successfully invited user IDs"
        }
      },
      required: [:success, :invited],
      example: %{
        "success" => true,
        "invited" => ["user_123", "user_456"]
      }
    })
  end

  defmodule JoinResponse do
    @moduledoc "Response after joining a huddle"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HuddleJoinResponse",
      description: "Response after joining a huddle",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        huddle_id: %Schema{type: :string, description: "Huddle ID"},
        session_id: %Schema{type: :string, description: "User's session ID for this huddle"},
        ice_servers: %Schema{
          type: :array,
          items: QuckAppRealtimeWeb.Schemas.Call.IceServer,
          description: "ICE servers for WebRTC connection"
        }
      },
      required: [:success, :huddle_id, :session_id],
      example: %{
        "success" => true,
        "huddle_id" => "huddle_abc123",
        "session_id" => "session_xyz789",
        "ice_servers" => [
          %{"urls" => ["stun:stun.quckapp.com:3478"]}
        ]
      }
    })
  end

  defmodule LeaveResponse do
    @moduledoc "Response after leaving a huddle"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HuddleLeaveResponse",
      description: "Response after leaving a huddle",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        huddle_ended: %Schema{type: :boolean, description: "Whether the huddle ended (last participant left)"}
      },
      required: [:success],
      example: %{
        "success" => true,
        "huddle_ended" => false
      }
    })
  end
end
