defmodule QuckChatRealtimeWeb.WebRTCChannel do
  @moduledoc """
  Phoenix Channel for WebRTC voice/video call signaling.

  Handles:
  - call:initiate - Start a new call
  - call:answer - Answer incoming call
  - call:reject - Reject incoming call
  - call:end - End active call
  - webrtc:offer - Send WebRTC offer
  - webrtc:answer - Send WebRTC answer
  - webrtc:ice-candidate - Exchange ICE candidates
  - call:toggle-audio - Mute/unmute audio
  - call:toggle-video - Enable/disable video
  """

  use QuckChatRealtimeWeb, :channel
  require Logger

  alias QuckChatRealtime.{CallManager, NotificationDispatcher, Presence}

  @call_timeout_ms 60_000  # 60 seconds ring timeout

  @impl true
  def join("webrtc:lobby", _params, socket) do
    user_id = socket.assigns.user_id
    send(self(), :after_join)

    # Register this socket for incoming calls
    CallManager.register_user(user_id, self())

    {:ok, %{ice_servers: get_ice_servers()}, socket}
  end

  def join("webrtc:" <> call_id, _params, socket) do
    user_id = socket.assigns.user_id

    # Verify user is participant of this call
    case CallManager.get_call(call_id) do
      {:ok, call} ->
        if user_id in call.participants do
          send(self(), {:after_join_call, call_id})
          socket = assign(socket, :call_id, call_id)
          {:ok, %{call: call, ice_servers: get_ice_servers()}, socket}
        else
          {:error, %{reason: "not_a_participant"}}
        end

      {:error, :not_found} ->
        {:error, %{reason: "call_not_found"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    user_id = socket.assigns.user_id

    # Track presence on WebRTC channel
    Presence.track_user(socket, user_id, %{
      channel: "webrtc",
      joined_at: System.system_time(:second)
    })

    # Check for pending calls
    case CallManager.get_pending_calls(user_id) do
      [] ->
        :ok

      pending_calls ->
        for call <- pending_calls do
          push(socket, "call:incoming", %{
            call_id: call.call_id,
            call_type: call.call_type,
            conversation_id: call.conversation_id,
            from: call.initiator_info
          })
        end
    end

    {:noreply, socket}
  end

  def handle_info({:after_join_call, call_id}, socket) do
    user_id = socket.assigns.user_id

    # Notify other participants
    broadcast_from!(socket, "call:participant:joined", %{
      call_id: call_id,
      user_id: user_id
    })

    {:noreply, socket}
  end

  def handle_info({:call_timeout, call_id}, socket) do
    case CallManager.get_call(call_id) do
      {:ok, call} when call.status == "ringing" ->
        # Call wasn't answered, mark as missed
        CallManager.end_call(call_id, "missed")
        broadcast!(socket, "call:missed", %{call_id: call_id})

      _ ->
        :ok
    end

    {:noreply, socket}
  end

  # Handle incoming call notifications from CallManager
  def handle_info({:incoming_call, call_data}, socket) do
    push(socket, "call:incoming", call_data)
    {:noreply, socket}
  end

  # ================== CALL LIFECYCLE ==================

  @impl true
  def handle_in("call:initiate", payload, socket) do
    user_id = socket.assigns.user_id
    conversation_id = payload["conversationId"]
    participants = payload["participants"]
    call_type = payload["callType"] || "audio"

    case CallManager.initiate_call(user_id, conversation_id, participants, call_type) do
      {:ok, call} ->
        # Send call notifications to participants
        Task.start(fn ->
          NotificationDispatcher.dispatch_call_notification(
            call.call_id,
            user_id,
            participants,
            call_type,
            conversation_id
          )
        end)

        # Schedule call timeout
        Process.send_after(self(), {:call_timeout, call.call_id}, @call_timeout_ms)

        {:reply, {:ok, %{
          call_id: call.call_id,
          ice_servers: get_ice_servers()
        }}, assign(socket, :call_id, call.call_id)}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("call:answer", %{"callId" => call_id}, socket) do
    user_id = socket.assigns.user_id

    case CallManager.answer_call(call_id, user_id) do
      {:ok, call} ->
        # Notify all participants that call was answered
        broadcast!(socket, "call:answered", %{
          call_id: call_id,
          user_id: user_id
        })

        {:reply, {:ok, %{
          call_id: call_id,
          ice_servers: get_ice_servers(),
          participants: call.participants
        }}, assign(socket, :call_id, call_id)}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("call:reject", %{"callId" => call_id}, socket) do
    user_id = socket.assigns.user_id

    case CallManager.reject_call(call_id, user_id) do
      :ok ->
        broadcast!(socket, "call:rejected", %{
          call_id: call_id,
          user_id: user_id
        })

        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("call:end", %{"callId" => call_id}, socket) do
    user_id = socket.assigns.user_id

    case CallManager.end_call(call_id, "completed", user_id) do
      :ok ->
        broadcast!(socket, "call:ended", %{
          call_id: call_id,
          ended_by: user_id
        })

        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  # ================== WEBRTC SIGNALING ==================

  def handle_in("webrtc:offer", payload, socket) do
    user_id = socket.assigns.user_id
    target_user_id = payload["targetUserId"]
    call_id = payload["callId"]
    offer = payload["offer"]

    # Send offer to target user
    CallManager.send_to_user(target_user_id, "webrtc:offer", %{
      call_id: call_id,
      from: user_id,
      offer: offer
    })

    {:reply, :ok, socket}
  end

  def handle_in("webrtc:answer", payload, socket) do
    user_id = socket.assigns.user_id
    target_user_id = payload["targetUserId"]
    call_id = payload["callId"]
    answer = payload["answer"]

    # Send answer to target user
    CallManager.send_to_user(target_user_id, "webrtc:answer", %{
      call_id: call_id,
      from: user_id,
      answer: answer
    })

    {:reply, :ok, socket}
  end

  def handle_in("webrtc:ice-candidate", payload, socket) do
    user_id = socket.assigns.user_id
    target_user_id = payload["targetUserId"]
    call_id = payload["callId"]
    candidate = payload["candidate"]

    # Send ICE candidate to target user
    CallManager.send_to_user(target_user_id, "webrtc:ice-candidate", %{
      call_id: call_id,
      from: user_id,
      candidate: candidate
    })

    {:reply, :ok, socket}
  end

  # ================== MEDIA CONTROLS ==================

  def handle_in("call:toggle-audio", %{"callId" => call_id, "enabled" => enabled}, socket) do
    user_id = socket.assigns.user_id

    broadcast_from!(socket, "call:participant:audio-toggled", %{
      call_id: call_id,
      user_id: user_id,
      enabled: enabled
    })

    {:reply, :ok, socket}
  end

  def handle_in("call:toggle-video", %{"callId" => call_id, "enabled" => enabled}, socket) do
    user_id = socket.assigns.user_id

    broadcast_from!(socket, "call:participant:video-toggled", %{
      call_id: call_id,
      user_id: user_id,
      enabled: enabled
    })

    {:reply, :ok, socket}
  end

  # ================== DISCONNECT HANDLING ==================

  @impl true
  def terminate(_reason, socket) do
    user_id = socket.assigns.user_id
    call_id = socket.assigns[:call_id]

    # Unregister from CallManager
    CallManager.unregister_user(user_id)

    # Handle active call disconnect
    if call_id do
      case CallManager.get_call(call_id) do
        {:ok, call} when call.status == "active" ->
          # Notify others about disconnection
          broadcast!(socket, "call:participant:disconnected", %{
            call_id: call_id,
            user_id: user_id
          })

        {:ok, call} when call.status == "ringing" and call.initiator == user_id ->
          # Initiator disconnected while ringing - end the call
          CallManager.end_call(call_id, "cancelled")
          broadcast!(socket, "call:cancelled", %{call_id: call_id})

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
end
