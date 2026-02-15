defmodule QuckAppRealtimeWeb.PresenceController do
  @moduledoc """
  Controller for presence and typing indicator operations.

  Handles:
  - User presence status queries
  - Online users listing
  - Typing indicators
  """
  use QuckAppRealtimeWeb, :controller
  use OpenApiSpex.ControllerSpecs
  require Logger

  alias QuckAppRealtime.PresenceTracker
  alias QuckAppRealtimeWeb.Schemas.{Common, Presence}

  tags ["Presence"]

  operation :show,
    summary: "Get user presence",
    description: "Get the presence status of a specific user",
    parameters: [
      user_id: [in: :path, type: :string, description: "User ID", required: true]
    ],
    responses: [
      ok: {"User presence", "application/json", Presence.PresenceResponse},
      not_found: {"User not found", "application/json", Common.ErrorResponse}
    ],
    security: [%{"bearerAuth" => []}]

  @doc "Get user presence status"
  def show(conn, %{"user_id" => user_id}) do
    case PresenceTracker.get_presence(user_id) do
      {:ok, presence} ->
        conn
        |> put_status(:ok)
        |> json(%{
          success: true,
          presence: presence
        })

      {:error, :not_found} ->
        # User exists but is offline
        conn
        |> put_status(:ok)
        |> json(%{
          success: true,
          presence: %{
            user_id: user_id,
            status: "offline",
            last_seen: nil
          }
        })
    end
  end

  operation :online_users,
    summary: "Get online users",
    description: "Get a list of currently online users (optionally filtered by workspace/channel)",
    parameters: [
      workspace_id: [in: :query, type: :string, description: "Filter by workspace ID", required: false],
      channel_id: [in: :query, type: :string, description: "Filter by channel ID", required: false],
      limit: [in: :query, type: :integer, description: "Maximum number of users to return", required: false]
    ],
    responses: [
      ok: {"Online users", "application/json", Presence.OnlineUsersResponse}
    ],
    security: [%{"bearerAuth" => []}]

  @doc "Get list of online users"
  def online_users(conn, params) do
    filters = %{
      workspace_id: params["workspace_id"],
      channel_id: params["channel_id"],
      limit: params["limit"] || 100
    }

    {:ok, users} = PresenceTracker.get_online_users(filters)

    conn
    |> put_status(:ok)
    |> json(%{
      success: true,
      users: users,
      count: length(users)
    })
  end

  operation :typing_users,
    summary: "Get typing users",
    description: "Get users currently typing in a conversation",
    parameters: [
      conversation_id: [in: :path, type: :string, description: "Conversation ID", required: true]
    ],
    responses: [
      ok: {"Typing users", "application/json", Presence.TypingUsersResponse}
    ],
    security: [%{"bearerAuth" => []}]

  @doc "Get users currently typing in a conversation"
  def typing_users(conn, %{"conversation_id" => conversation_id}) do
    {:ok, typing} = PresenceTracker.get_typing_users(conversation_id)

    conn
    |> put_status(:ok)
    |> json(%{
      success: true,
      conversation_id: conversation_id,
      typing: typing
    })
  end
end
