defmodule QuckChatRealtimeWeb.HuddleChannel do
  @moduledoc """
  Phoenix Channel for Huddle - persistent group audio/video rooms.

  Unlike 1-on-1 calls, Huddles are:
  - Persistent rooms tied to a conversation/channel
  - Users can join/leave freely
  - Multiple participants (like Discord voice channels)
  - Optional video/screen sharing

  Handles:
  - huddle:create - Create a new huddle
  - huddle:join - Join an existing huddle
  - huddle:leave - Leave a huddle
  - huddle:invite - Invite users to huddle
  - webrtc:* - WebRTC signaling for huddle participants
  - huddle:toggle-audio - Mute/unmute
  - huddle:toggle-video - Enable/disable video
  - huddle:toggle-screen - Start/stop screen sharing
  - huddle:raise-hand - Raise hand (for moderated rooms)
  """

  use QuckChatRealtimeWeb, :channel
  require Logger

  alias QuckChatRealtime.{HuddleManager, NotificationDispatcher, Presence}

  @impl true
  def join("huddle:lobby", _params, socket) do
    user_id = socket.assigns.user_id
    send(self(), :after_join)

    # Get user's active huddles
    active_huddles = HuddleManager.get_user_huddles(user_id)

    {:ok, %{active_huddles: active_huddles}, socket}
  end

  def join("huddle:" <> huddle_id, params, socket) do
    user_id = socket.assigns.user_id

    case HuddleManager.join_huddle(huddle_id, user_id, params) do
      {:ok, huddle} ->
        send(self(), {:after_join_huddle, huddle_id})
        socket = socket
          |> assign(:huddle_id, huddle_id)
          |> assign(:audio_enabled, true)
          |> assign(:video_enabled, params["video"] || false)

        {:ok, %{
          huddle: huddle,
          participants: huddle.participants,
          ice_servers: get_ice_servers()
        }, socket}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    user_id = socket.assigns.user_id

    Presence.track_user(socket, user_id, %{
      channel: "huddle_lobby",
      joined_at: System.system_time(:second)
    })

    {:noreply, socket}
  end

  def handle_info({:after_join_huddle, huddle_id}, socket) do
    user_id = socket.assigns.user_id

    # Track presence in huddle
    Presence.track_user(socket, user_id, %{
      huddle_id: huddle_id,
      audio_enabled: socket.assigns.audio_enabled,
      video_enabled: socket.assigns.video_enabled,
      joined_at: System.system_time(:second)
    })

    # Notify other participants
    broadcast_from!(socket, "huddle:participant:joined", %{
      huddle_id: huddle_id,
      user_id: user_id,
      audio_enabled: socket.assigns.audio_enabled,
      video_enabled: socket.assigns.video_enabled
    })

    # Send current presence state
    push(socket, "presence_state", Presence.list(socket))

    {:noreply, socket}
  end

  # ================== HUDDLE LIFECYCLE ==================

  @impl true
  def handle_in("huddle:create", payload, socket) do
    user_id = socket.assigns.user_id
    conversation_id = payload["conversationId"]
    name = payload["name"] || "Huddle"

    case HuddleManager.create_huddle(user_id, conversation_id, name) do
      {:ok, huddle} ->
        # Notify conversation about new huddle
        Phoenix.PubSub.broadcast(
          QuckChatRealtime.PubSub,
          "conversation:#{conversation_id}",
          {:huddle_started, huddle}
        )

        {:reply, {:ok, %{
          huddle_id: huddle.huddle_id,
          conversation_id: conversation_id
        }}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("huddle:leave", %{"huddleId" => huddle_id}, socket) do
    user_id = socket.assigns.user_id

    case HuddleManager.leave_huddle(huddle_id, user_id) do
      {:ok, remaining_count} ->
        broadcast_from!(socket, "huddle:participant:left", %{
          huddle_id: huddle_id,
          user_id: user_id
        })

        # If no one left, end the huddle
        if remaining_count == 0 do
          HuddleManager.end_huddle(huddle_id)
          broadcast!(socket, "huddle:ended", %{huddle_id: huddle_id})
        end

        socket = assign(socket, :huddle_id, nil)
        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("huddle:invite", payload, socket) do
    user_id = socket.assigns.user_id
    huddle_id = payload["huddleId"] || socket.assigns[:huddle_id]
    invitee_ids = payload["userIds"]

    case HuddleManager.get_huddle(huddle_id) do
      {:ok, huddle} ->
        # Send invitations
        Task.start(fn ->
          NotificationDispatcher.dispatch_huddle_invitation(
            huddle_id,
            user_id,
            invitee_ids,
            huddle.conversation_id
          )
        end)

        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  # ================== WEBRTC SIGNALING FOR HUDDLE ==================

  def handle_in("webrtc:offer", payload, socket) do
    user_id = socket.assigns.user_id
    target_user_id = payload["targetUserId"]
    huddle_id = payload["huddleId"] || socket.assigns[:huddle_id]

    HuddleManager.send_to_participant(huddle_id, target_user_id, "webrtc:offer", %{
      huddle_id: huddle_id,
      from: user_id,
      offer: payload["offer"]
    })

    {:reply, :ok, socket}
  end

  def handle_in("webrtc:answer", payload, socket) do
    user_id = socket.assigns.user_id
    target_user_id = payload["targetUserId"]
    huddle_id = payload["huddleId"] || socket.assigns[:huddle_id]

    HuddleManager.send_to_participant(huddle_id, target_user_id, "webrtc:answer", %{
      huddle_id: huddle_id,
      from: user_id,
      answer: payload["answer"]
    })

    {:reply, :ok, socket}
  end

  def handle_in("webrtc:ice-candidate", payload, socket) do
    user_id = socket.assigns.user_id
    target_user_id = payload["targetUserId"]
    huddle_id = payload["huddleId"] || socket.assigns[:huddle_id]

    HuddleManager.send_to_participant(huddle_id, target_user_id, "webrtc:ice-candidate", %{
      huddle_id: huddle_id,
      from: user_id,
      candidate: payload["candidate"]
    })

    {:reply, :ok, socket}
  end

  # ================== MEDIA CONTROLS ==================

  def handle_in("huddle:toggle-audio", %{"enabled" => enabled}, socket) do
    user_id = socket.assigns.user_id
    huddle_id = socket.assigns[:huddle_id]

    socket = assign(socket, :audio_enabled, enabled)

    # Update presence
    Presence.update_user(socket, user_id, %{audio_enabled: enabled})

    broadcast_from!(socket, "huddle:participant:audio-toggled", %{
      huddle_id: huddle_id,
      user_id: user_id,
      enabled: enabled
    })

    {:reply, :ok, socket}
  end

  def handle_in("huddle:toggle-video", %{"enabled" => enabled}, socket) do
    user_id = socket.assigns.user_id
    huddle_id = socket.assigns[:huddle_id]

    socket = assign(socket, :video_enabled, enabled)

    # Update presence
    Presence.update_user(socket, user_id, %{video_enabled: enabled})

    broadcast_from!(socket, "huddle:participant:video-toggled", %{
      huddle_id: huddle_id,
      user_id: user_id,
      enabled: enabled
    })

    {:reply, :ok, socket}
  end

  def handle_in("huddle:toggle-screen", %{"enabled" => enabled}, socket) do
    user_id = socket.assigns.user_id
    huddle_id = socket.assigns[:huddle_id]

    # Only one user can share screen at a time
    if enabled do
      case HuddleManager.start_screen_share(huddle_id, user_id) do
        :ok ->
          broadcast!(socket, "huddle:screen-share:started", %{
            huddle_id: huddle_id,
            user_id: user_id
          })
          {:reply, :ok, socket}

        {:error, :already_sharing} ->
          {:reply, {:error, %{reason: "someone_already_sharing"}}, socket}
      end
    else
      HuddleManager.stop_screen_share(huddle_id, user_id)
      broadcast!(socket, "huddle:screen-share:stopped", %{
        huddle_id: huddle_id,
        user_id: user_id
      })
      {:reply, :ok, socket}
    end
  end

  def handle_in("huddle:raise-hand", %{"raised" => raised}, socket) do
    user_id = socket.assigns.user_id
    huddle_id = socket.assigns[:huddle_id]

    broadcast!(socket, "huddle:hand-raised", %{
      huddle_id: huddle_id,
      user_id: user_id,
      raised: raised
    })

    {:reply, :ok, socket}
  end

  # ================== CHAT IN HUDDLE ==================

  def handle_in("huddle:message", %{"content" => content}, socket) do
    user_id = socket.assigns.user_id
    huddle_id = socket.assigns[:huddle_id]

    message = %{
      id: generate_id(),
      huddle_id: huddle_id,
      sender_id: user_id,
      content: content,
      created_at: DateTime.utc_now()
    }

    broadcast!(socket, "huddle:message:new", message)

    {:reply, :ok, socket}
  end

  # ================== PRESENCE HANDLING ==================

  @impl true
  def handle_info(%{event: "presence_diff", payload: diff}, socket) do
    push(socket, "presence_diff", diff)
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    user_id = socket.assigns.user_id
    huddle_id = socket.assigns[:huddle_id]

    if huddle_id do
      case HuddleManager.leave_huddle(huddle_id, user_id) do
        {:ok, remaining_count} ->
          broadcast!(socket, "huddle:participant:left", %{
            huddle_id: huddle_id,
            user_id: user_id
          })

          if remaining_count == 0 do
            HuddleManager.end_huddle(huddle_id)
          end

        _ ->
          :ok
      end
    end

    Presence.untrack_user(socket, user_id)
    :ok
  end

  # ================== PRIVATE FUNCTIONS ==================

  defp get_ice_servers do
    config = Application.get_env(:quckchat_realtime, :ice_servers, [])

    stun = Keyword.get(config, :stun, "stun:stun.l.google.com:19302")
    turn_url = Keyword.get(config, :turn_url)
    turn_username = Keyword.get(config, :turn_username)
    turn_credential = Keyword.get(config, :turn_credential)

    servers = [%{urls: stun}]

    if turn_url && turn_username && turn_credential do
      servers ++ [%{
        urls: turn_url,
        username: turn_username,
        credential: turn_credential
      }]
    else
      servers
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
