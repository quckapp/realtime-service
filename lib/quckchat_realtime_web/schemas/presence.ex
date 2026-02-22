defmodule QuckAppRealtimeWeb.Schemas.Presence do
  @moduledoc """
  Schemas for presence-related API operations.
  """
  alias OpenApiSpex.Schema

  defmodule UserPresence do
    @moduledoc "User presence information"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "UserPresence",
      description: "User presence information",
      type: :object,
      properties: %{
        user_id: %Schema{type: :string, description: "User ID"},
        status: %Schema{
          type: :string,
          enum: ["online", "away", "busy", "offline"],
          description: "User's current status"
        },
        last_seen: %Schema{type: :string, format: :"date-time", description: "Last activity timestamp"},
        status_text: %Schema{type: :string, description: "Custom status text"},
        status_emoji: %Schema{type: :string, description: "Status emoji"},
        in_call: %Schema{type: :boolean, description: "Whether user is currently in a call"},
        in_huddle: %Schema{type: :boolean, description: "Whether user is currently in a huddle"},
        device_type: %Schema{
          type: :string,
          enum: ["desktop", "mobile", "web"],
          description: "Active device type"
        }
      },
      required: [:user_id, :status],
      example: %{
        "user_id" => "user_123",
        "status" => "online",
        "last_seen" => "2024-01-15T10:30:00Z",
        "status_text" => "Working from home",
        "status_emoji" => ":house:",
        "in_call" => false,
        "in_huddle" => false,
        "device_type" => "desktop"
      }
    })
  end

  defmodule PresenceResponse do
    @moduledoc "Response for user presence query"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PresenceResponse",
      description: "Response containing user presence information",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        presence: UserPresence
      },
      required: [:success, :presence],
      example: %{
        "success" => true,
        "presence" => %{
          "user_id" => "user_123",
          "status" => "online",
          "last_seen" => "2024-01-15T10:30:00Z",
          "in_call" => false,
          "in_huddle" => false
        }
      }
    })
  end

  defmodule OnlineUsersResponse do
    @moduledoc "Response for online users query"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "OnlineUsersResponse",
      description: "Response containing list of online users",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        users: %Schema{
          type: :array,
          items: UserPresence,
          description: "List of online users with their presence information"
        },
        count: %Schema{type: :integer, description: "Total number of online users"}
      },
      required: [:success, :users, :count],
      example: %{
        "success" => true,
        "users" => [
          %{
            "user_id" => "user_123",
            "status" => "online",
            "last_seen" => "2024-01-15T10:30:00Z"
          },
          %{
            "user_id" => "user_456",
            "status" => "away",
            "last_seen" => "2024-01-15T10:25:00Z"
          }
        ],
        "count" => 2
      }
    })
  end

  defmodule TypingUser do
    @moduledoc "User typing indicator"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TypingUser",
      description: "User typing indicator information",
      type: :object,
      properties: %{
        user_id: %Schema{type: :string, description: "User ID"},
        display_name: %Schema{type: :string, description: "User display name"},
        started_typing_at: %Schema{type: :string, format: :"date-time", description: "When user started typing"}
      },
      required: [:user_id],
      example: %{
        "user_id" => "user_123",
        "display_name" => "John Doe",
        "started_typing_at" => "2024-01-15T10:30:00Z"
      }
    })
  end

  defmodule TypingUsersResponse do
    @moduledoc "Response for typing users query"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TypingUsersResponse",
      description: "Response containing users currently typing in a conversation",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        conversation_id: %Schema{type: :string, description: "Conversation ID"},
        typing: %Schema{
          type: :array,
          items: TypingUser,
          description: "List of users currently typing"
        }
      },
      required: [:success, :conversation_id, :typing],
      example: %{
        "success" => true,
        "conversation_id" => "conv_789",
        "typing" => [
          %{
            "user_id" => "user_123",
            "display_name" => "John Doe",
            "started_typing_at" => "2024-01-15T10:30:00Z"
          }
        ]
      }
    })
  end
end
