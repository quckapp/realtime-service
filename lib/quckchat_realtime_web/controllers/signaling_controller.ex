defmodule QuckAppRealtimeWeb.SignalingController do
  @moduledoc """
  Controller for WebRTC signaling and ICE server configuration.

  Provides:
  - ICE server configuration
  - TURN credential generation
  - WebRTC diagnostics
  """
  use QuckAppRealtimeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias QuckAppRealtime.SignalingServer
  alias QuckAppRealtimeWeb.Schemas.Signaling

  tags ["Signaling"]

  operation :ice_config,
    summary: "Get ICE configuration",
    description: "Get full ICE server configuration for WebRTC connections (STUN/TURN servers)",
    responses: [
      ok: {"ICE configuration", "application/json", Signaling.IceConfigResponse}
    ],
    security: [%{"bearerAuth" => []}]

  @doc "Get full ICE configuration for WebRTC"
  def ice_config(conn, _params) do
    user_id = conn.assigns[:user_id] || "anonymous"
    config = SignalingServer.get_ice_config(user_id)

    conn
    |> put_status(:ok)
    |> json(%{success: true, config: config})
  end

  operation :turn_credentials,
    summary: "Generate TURN credentials",
    description: "Generate time-limited TURN credentials for WebRTC relay connections",
    request_body: {"TURN credentials request", "application/json", Signaling.TurnCredentialsRequest, required: false},
    responses: [
      ok: {"TURN credentials", "application/json", Signaling.TurnCredentialsResponse}
    ],
    security: [%{"bearerAuth" => []}]

  @doc "Generate time-limited TURN credentials"
  def turn_credentials(conn, _params) do
    user_id = conn.assigns[:user_id] || "anonymous"
    credentials = SignalingServer.generate_turn_credentials(user_id)

    conn
    |> put_status(:ok)
    |> json(%{
      success: true,
      credentials: %{
        username: credentials.username,
        credential: credentials.credential,
        ttl: credentials.ttl,
        urls: credentials.urls
      }
    })
  end
end
