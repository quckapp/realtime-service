defmodule QuckChatRealtimeWeb.SignalingController do
  @moduledoc """
  Controller for WebRTC signaling and ICE server configuration.

  Provides:
  - ICE server configuration
  - TURN credential generation
  - WebRTC diagnostics
  """
  use QuckChatRealtimeWeb, :controller

  alias QuckChatRealtime.SignalingServer

  @doc "Get full ICE configuration for WebRTC"
  def ice_config(conn, _params) do
    user_id = conn.assigns[:user_id] || "anonymous"
    config = SignalingServer.get_ice_config(user_id)

    conn
    |> put_status(:ok)
    |> json(%{success: true, config: config})
  end

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
