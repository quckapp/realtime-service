defmodule QuckAppRealtimeWeb.HuddleController do
  @moduledoc """
  Controller for huddle management operations.

  Huddles are quick, informal audio meetings typically used within channels.

  Handles:
  - Creating huddles
  - Inviting users to huddles
  - Joining/leaving huddles
  - Getting huddle information
  """
  use QuckAppRealtimeWeb, :controller
  use OpenApiSpex.ControllerSpecs
  require Logger

  alias QuckAppRealtime.{HuddleManager, SignalingServer}
  alias QuckAppRealtimeWeb.Schemas.{Common, Huddle}

  tags ["Huddles"]

  operation :create,
    summary: "Create huddle",
    description: "Create a new huddle (quick audio meeting) in a channel",
    request_body: {"Huddle creation request", "application/json", Huddle.CreateRequest},
    responses: [
      created: {"Huddle created", "application/json", Huddle.CreateResponse},
      conflict: {"Huddle already exists in channel", "application/json", Common.ErrorResponse},
      internal_server_error: {"Server error", "application/json", Common.ErrorResponse}
    ],
    security: [%{"bearerAuth" => []}]

  @doc "Create a new huddle"
  def create(conn, params) do
    user_id = conn.assigns.user_id

    huddle_params = %{
      name: params["name"],
      channel_id: params["channel_id"],
      workspace_id: params["workspace_id"],
      created_by: user_id,
      audio_only: Map.get(params, "audio_only", true),
      initial_participants: Map.get(params, "initial_participants", [])
    }

    case HuddleManager.create_huddle(huddle_params) do
      {:ok, huddle} ->
        Logger.info("Huddle created: #{huddle.huddle_id} by #{user_id}")

        conn
        |> put_status(:created)
        |> json(%{
          success: true,
          huddle: %{
            huddle_id: huddle.huddle_id,
            name: huddle.name,
            channel_id: huddle.channel_id,
            created_by: huddle.created_by,
            created_at: huddle.created_at,
            join_url: "https://app.quckapp.com/huddle/#{huddle.huddle_id}"
          }
        })

      {:error, :huddle_exists} ->
        conn
        |> put_status(:conflict)
        |> json(%{success: false, error: "huddle_exists", message: "A huddle already exists in this channel"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason})
    end
  end

  operation :show,
    summary: "Get huddle",
    description: "Get details of a specific huddle",
    parameters: [
      huddle_id: [in: :path, type: :string, description: "Huddle ID", required: true]
    ],
    responses: [
      ok: {"Huddle details", "application/json", Huddle.ShowResponse},
      not_found: {"Huddle not found", "application/json", Common.ErrorResponse}
    ],
    security: [%{"bearerAuth" => []}]

  @doc "Get huddle details"
  def show(conn, %{"huddle_id" => huddle_id}) do
    case HuddleManager.get_huddle(huddle_id) do
      {:ok, huddle} ->
        conn
        |> put_status(:ok)
        |> json(%{
          success: true,
          huddle: huddle
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "huddle_not_found"})
    end
  end

  operation :invite,
    summary: "Invite to huddle",
    description: "Invite users to join a huddle",
    parameters: [
      huddle_id: [in: :path, type: :string, description: "Huddle ID", required: true]
    ],
    request_body: {"Invite request", "application/json", Huddle.InviteRequest},
    responses: [
      ok: {"Invitations sent", "application/json", Huddle.InviteResponse},
      not_found: {"Huddle not found", "application/json", Common.ErrorResponse},
      internal_server_error: {"Server error", "application/json", Common.ErrorResponse}
    ],
    security: [%{"bearerAuth" => []}]

  @doc "Invite users to a huddle"
  def invite(conn, %{"huddle_id" => huddle_id} = params) do
    user_id = conn.assigns.user_id
    user_ids = Map.get(params, "user_ids", [])

    case HuddleManager.invite_to_huddle(huddle_id, user_ids, user_id) do
      {:ok, invited} ->
        Logger.info("Users invited to huddle #{huddle_id}: #{inspect(user_ids)}")

        conn
        |> put_status(:ok)
        |> json(%{success: true, invited: invited})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "huddle_not_found"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason})
    end
  end

  operation :join,
    summary: "Join huddle",
    description: "Join an existing huddle",
    parameters: [
      huddle_id: [in: :path, type: :string, description: "Huddle ID", required: true]
    ],
    responses: [
      ok: {"Joined huddle", "application/json", Huddle.JoinResponse},
      not_found: {"Huddle not found", "application/json", Common.ErrorResponse},
      conflict: {"Already in huddle", "application/json", Common.ErrorResponse}
    ],
    security: [%{"bearerAuth" => []}]

  @doc "Join a huddle"
  def join(conn, %{"huddle_id" => huddle_id}) do
    user_id = conn.assigns.user_id

    case HuddleManager.join_huddle(huddle_id, user_id) do
      {:ok, session} ->
        ice_servers = SignalingServer.get_ice_servers(user_id)

        Logger.info("User #{user_id} joined huddle #{huddle_id}")

        conn
        |> put_status(:ok)
        |> json(%{
          success: true,
          huddle_id: huddle_id,
          session_id: session.session_id,
          ice_servers: ice_servers
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "huddle_not_found"})

      {:error, :already_joined} ->
        conn
        |> put_status(:conflict)
        |> json(%{success: false, error: "already_joined", message: "Already in this huddle"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason})
    end
  end

  operation :leave,
    summary: "Leave huddle",
    description: "Leave a huddle you are currently in",
    parameters: [
      huddle_id: [in: :path, type: :string, description: "Huddle ID", required: true]
    ],
    responses: [
      ok: {"Left huddle", "application/json", Huddle.LeaveResponse},
      not_found: {"Huddle not found or not in huddle", "application/json", Common.ErrorResponse}
    ],
    security: [%{"bearerAuth" => []}]

  @doc "Leave a huddle"
  def leave(conn, %{"huddle_id" => huddle_id}) do
    user_id = conn.assigns.user_id

    case HuddleManager.leave_huddle(huddle_id, user_id) do
      {:ok, result} ->
        Logger.info("User #{user_id} left huddle #{huddle_id}")

        conn
        |> put_status(:ok)
        |> json(%{
          success: true,
          huddle_ended: Map.get(result, :huddle_ended, false)
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "huddle_not_found"})

      {:error, :not_in_huddle} ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "not_in_huddle", message: "Not currently in this huddle"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason})
    end
  end
end
