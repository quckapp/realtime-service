defmodule QuckChatRealtimeWeb.PresenceChannel do
  @moduledoc """
  Phoenix Channel for user presence tracking.

  Provides real-time updates about:
  - User online/offline status
  - User activity status (active, away, busy, dnd)
  - Last seen timestamps
  - Device information
  """

  use QuckChatRealtimeWeb, :channel
  require Logger

  alias QuckChatRealtime.Presence

  @impl true
  def join("presence:global", _params, socket) do
    send(self(), :after_join)
    {:ok, socket}
  end

  def join("presence:" <> conversation_id, _params, socket) do
    send(self(), {:after_join, conversation_id})
    socket = assign(socket, :conversation_id, conversation_id)
    {:ok, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    user_id = socket.assigns.user_id

    Presence.track_user(socket, user_id, %{
      status: "online",
      device: socket.assigns[:user_agent] || "unknown",
      joined_at: System.system_time(:second)
    })

    push(socket, "presence_state", Presence.list(socket))

    {:noreply, socket}
  end

  def handle_info({:after_join, conversation_id}, socket) do
    user_id = socket.assigns.user_id

    Presence.track_user(socket, user_id, %{
      status: "online",
      conversation_id: conversation_id,
      joined_at: System.system_time(:second)
    })

    push(socket, "presence_state", Presence.list(socket))

    {:noreply, socket}
  end

  # ================== STATUS UPDATES ==================

  @impl true
  def handle_in("status:update", %{"status" => status}, socket) do
    user_id = socket.assigns.user_id

    # Validate status
    valid_statuses = ["online", "away", "busy", "dnd", "invisible"]

    if status in valid_statuses do
      Presence.update_user(socket, user_id, %{status: status})

      # Broadcast to all channels this user is part of
      broadcast!(socket, "user:status:changed", %{
        user_id: user_id,
        status: status
      })

      {:reply, :ok, socket}
    else
      {:reply, {:error, %{reason: "invalid_status"}}, socket}
    end
  end

  def handle_in("status:custom", %{"text" => text, "emoji" => emoji}, socket) do
    user_id = socket.assigns.user_id

    Presence.update_user(socket, user_id, %{
      custom_status: %{
        text: String.slice(text || "", 0..100),
        emoji: emoji
      }
    })

    broadcast!(socket, "user:custom_status:changed", %{
      user_id: user_id,
      custom_status: %{text: text, emoji: emoji}
    })

    {:reply, :ok, socket}
  end

  def handle_in("status:clear_custom", _params, socket) do
    user_id = socket.assigns.user_id

    Presence.update_user(socket, user_id, %{custom_status: nil})

    broadcast!(socket, "user:custom_status:changed", %{
      user_id: user_id,
      custom_status: nil
    })

    {:reply, :ok, socket}
  end

  # ================== ACTIVITY TRACKING ==================

  def handle_in("activity:typing", %{"conversationId" => conversation_id}, socket) do
    user_id = socket.assigns.user_id

    # Update last activity
    Presence.update_user(socket, user_id, %{
      last_activity: System.system_time(:second),
      activity_type: "typing"
    })

    {:noreply, socket}
  end

  def handle_in("activity:viewing", %{"conversationId" => conversation_id}, socket) do
    user_id = socket.assigns.user_id

    Presence.update_user(socket, user_id, %{
      current_conversation: conversation_id,
      last_activity: System.system_time(:second)
    })

    {:noreply, socket}
  end

  # ================== QUERIES ==================

  def handle_in("presence:get", %{"userIds" => user_ids}, socket) when is_list(user_ids) do
    presence_data =
      user_ids
      |> Enum.map(fn user_id ->
        case Presence.get_user_presence(user_id) do
          nil -> %{user_id: user_id, status: "offline"}
          data -> Map.put(data, :user_id, user_id)
        end
      end)

    {:reply, {:ok, %{users: presence_data}}, socket}
  end

  def handle_in("presence:get", %{"userId" => user_id}, socket) do
    case Presence.get_user_presence(user_id) do
      nil ->
        {:reply, {:ok, %{user_id: user_id, status: "offline"}}, socket}

      data ->
        {:reply, {:ok, Map.put(data, :user_id, user_id)}, socket}
    end
  end

  # ================== PRESENCE DIFF HANDLING ==================

  @impl true
  def handle_info(%{event: "presence_diff", payload: diff}, socket) do
    push(socket, "presence_diff", diff)
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    user_id = socket.assigns.user_id
    Presence.untrack_user(socket, user_id)

    # Broadcast offline status
    broadcast!(socket, "user:offline", %{
      user_id: user_id,
      last_seen: System.system_time(:second)
    })

    :ok
  end
end
