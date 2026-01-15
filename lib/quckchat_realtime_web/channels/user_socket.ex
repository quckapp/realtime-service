defmodule QuckAppRealtimeWeb.UserSocket do
  @moduledoc """
  Main WebSocket handler for all real-time communication.

  Handles authentication via JWT and routes to appropriate channels:
  - chat:* - Messaging, typing indicators, reactions
  - webrtc:* - Voice/video call signaling
  - huddle:* - Group audio/video rooms
  - presence:* - User presence updates
  """

  use Phoenix.Socket
  require Logger

  alias QuckAppRealtime.Guardian

  # Channels
  channel "chat:*", QuckAppRealtimeWeb.ChatChannel
  channel "webrtc:*", QuckAppRealtimeWeb.WebRTCChannel
  channel "huddle:*", QuckAppRealtimeWeb.HuddleChannel
  channel "presence:*", QuckAppRealtimeWeb.PresenceChannel

  @impl true
  def connect(params, socket, connect_info) do
    token = get_token(params, connect_info)

    case Guardian.verify_token(token) do
      {:ok, user_id} ->
        Logger.info("Socket connected for user: #{user_id}")

        socket =
          socket
          |> assign(:user_id, user_id)
          |> assign(:connected_at, System.system_time(:second))
          |> assign(:user_agent, get_user_agent(connect_info))
          |> assign(:ip_address, get_ip_address(connect_info))

        {:ok, socket}

      {:error, reason} ->
        Logger.warning("Socket connection failed: #{inspect(reason)}")
        :error
    end
  end

  @impl true
  def id(socket), do: "users_socket:#{socket.assigns.user_id}"

  # Token extraction helpers

  defp get_token(params, connect_info) do
    # Try multiple sources for the token
    params["token"] ||
      params["auth_token"] ||
      get_header_token(connect_info) ||
      ""
  end

  defp get_header_token(%{x_headers: headers}) when is_list(headers) do
    case List.keyfind(headers, "authorization", 0) do
      {"authorization", "Bearer " <> token} -> token
      _ -> nil
    end
  end

  defp get_header_token(_), do: nil

  defp get_user_agent(%{x_headers: headers}) when is_list(headers) do
    case List.keyfind(headers, "user-agent", 0) do
      {"user-agent", ua} -> ua
      _ -> "unknown"
    end
  end

  defp get_user_agent(_), do: "unknown"

  defp get_ip_address(%{peer_data: %{address: ip}}) when is_tuple(ip) do
    ip |> Tuple.to_list() |> Enum.join(".")
  end

  defp get_ip_address(%{x_headers: headers}) when is_list(headers) do
    case List.keyfind(headers, "x-forwarded-for", 0) do
      {"x-forwarded-for", ip} -> ip |> String.split(",") |> List.first() |> String.trim()
      _ -> "unknown"
    end
  end

  defp get_ip_address(_), do: "unknown"
end
