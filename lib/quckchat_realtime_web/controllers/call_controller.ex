defmodule QuckAppRealtimeWeb.CallController do
  @moduledoc """
  Controller for call management operations.

  Handles:
  - Inviting participants to calls
  - Getting call participants
  - ICE server configuration for calls
  """
  use QuckAppRealtimeWeb, :controller
  use OpenApiSpex.ControllerSpecs
  require Logger

  alias QuckAppRealtime.{CallManager, SignalingServer}
  alias QuckAppRealtimeWeb.Schemas.{Common, Call}

  tags ["Calls"]

  operation :invite,
    summary: "Invite to call",
    description: "Invite one or more users to join an existing call",
    parameters: [
      call_id: [in: :path, type: :string, description: "Call ID", required: true]
    ],
    request_body: {"Invite request", "application/json", Call.InviteRequest},
    responses: [
      ok: {"Invitations sent", "application/json", Call.InviteResponse},
      not_found: {"Call not found", "application/json", Common.ErrorResponse},
      internal_server_error: {"Server error", "application/json", Common.ErrorResponse}
    ],
    security: [%{"bearerAuth" => []}]

  @doc "Invite participants to a call"
  def invite(conn, %{"call_id" => call_id} = params) do
    user_id = conn.assigns.user_id
    user_ids = Map.get(params, "user_ids", [])

    case CallManager.invite_to_call(call_id, user_ids, user_id) do
      {:ok, result} ->
        Logger.info("Users invited to call #{call_id}: #{inspect(user_ids)}")

        conn
        |> put_status(:ok)
        |> json(%{
          success: true,
          invited: result.invited,
          failed: Map.get(result, :failed, [])
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "call_not_found"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason})
    end
  end

  operation :participants,
    summary: "Get call participants",
    description: "Get the list of participants in a call",
    parameters: [
      call_id: [in: :path, type: :string, description: "Call ID", required: true]
    ],
    responses: [
      ok: {"Participants list", "application/json", Call.ParticipantsResponse},
      not_found: {"Call not found", "application/json", Common.ErrorResponse}
    ],
    security: [%{"bearerAuth" => []}]

  @doc "Get call participants"
  def participants(conn, %{"call_id" => call_id}) do
    case CallManager.get_participants(call_id) do
      {:ok, participants} ->
        conn
        |> put_status(:ok)
        |> json(%{
          success: true,
          call_id: call_id,
          participants: participants,
          count: length(participants)
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "call_not_found"})
    end
  end

  operation :ice_servers,
    summary: "Get ICE servers for call",
    description: "Get ICE server configuration for a specific call",
    parameters: [
      call_id: [in: :path, type: :string, description: "Call ID", required: true]
    ],
    responses: [
      ok: {"ICE servers", "application/json", Call.IceServersResponse},
      not_found: {"Call not found", "application/json", Common.ErrorResponse}
    ],
    security: [%{"bearerAuth" => []}]

  @doc "Get ICE servers for a call"
  def ice_servers(conn, %{"call_id" => call_id}) do
    user_id = conn.assigns[:user_id] || "anonymous"

    case CallManager.get_call(call_id) do
      {:ok, _call} ->
        ice_servers = SignalingServer.get_ice_servers(user_id)

        conn
        |> put_status(:ok)
        |> json(%{
          success: true,
          ice_servers: ice_servers,
          ttl: 86400
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "call_not_found"})
    end
  end
end
