defmodule QuckAppRealtimeWeb.ChatChannel do
  @moduledoc """
  Phoenix Channel for real-time messaging.

  Handles:
  - message:send - Send new messages
  - message:edit - Edit existing messages
  - message:delete - Delete messages
  - message:reaction:add - Add emoji reactions
  - message:reaction:remove - Remove emoji reactions
  - message:read - Mark messages as read
  - typing:start - Typing indicator start
  - typing:stop - Typing indicator stop
  """

  use QuckAppRealtimeWeb, :channel
  require Logger

  alias QuckAppRealtime.{Presence, Mongo, NotificationDispatcher}

  @impl true
  def join("chat:lobby", _params, socket) do
    send(self(), :after_join)
    {:ok, socket}
  end

  def join("chat:" <> conversation_id, _params, socket) do
    user_id = socket.assigns.user_id
    external_id = socket.assigns[:external_id]

    # Log for debugging
    Logger.info("Chat join attempt - user_id: #{user_id}, external_id: #{external_id || "nil"}, conversation: #{conversation_id}")

    # TODO: Re-enable strict verification once user ID mapping is fixed between Spring auth and MongoDB
    # For now, verify conversation exists but allow join if user has valid token
    case verify_conversation_exists(conversation_id) do
      :ok ->
        send(self(), {:after_join, conversation_id})
        socket = assign(socket, :conversation_id, conversation_id)
        {:ok, %{conversation_id: conversation_id}, socket}

      {:error, reason} ->
        Logger.warning("Chat join failed - conversation #{conversation_id} not found: #{reason}")
        {:error, %{reason: reason}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    user_id = socket.assigns.user_id

    # Track presence
    Presence.track_user(socket, user_id, %{
      device: socket.assigns[:user_agent] || "unknown",
      joined_at: System.system_time(:second)
    })

    # Broadcast online status
    broadcast!(socket, "user:online", %{user_id: user_id})

    {:noreply, socket}
  end

  def handle_info({:after_join, conversation_id}, socket) do
    user_id = socket.assigns.user_id

    # Track presence in this conversation
    Presence.track_user(socket, user_id, %{
      conversation_id: conversation_id,
      joined_at: System.system_time(:second)
    })

    # Push current presence state
    push(socket, "presence_state", Presence.list(socket))

    {:noreply, socket}
  end

  # ================== MESSAGE HANDLERS ==================

  @impl true
  def handle_in("message:send", payload, socket) do
    # Use external_id (MongoDB ObjectId) for sender_id in messages
    sender_id = socket.assigns[:external_id] || socket.assigns.user_id
    conversation_id = payload["conversationId"] || socket.assigns[:conversation_id]

    message = %{
      conversation_id: conversation_id,
      sender_id: sender_id,
      type: payload["type"] || "text",
      content: payload["content"],
      attachments: payload["attachments"] || [],
      reply_to: payload["replyTo"],
      is_forwarded: payload["isForwarded"] || false,
      forwarded_from: payload["forwardedFrom"],
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    # Insert message (in production, you'd call the NestJS API)
    case create_message(message) do
      {:ok, saved_message} ->
        # Broadcast to all participants in the conversation
        broadcast!(socket, "message:new", saved_message)

        # Send push notifications to offline users
        Task.start(fn ->
          NotificationDispatcher.dispatch_message_notification(
            conversation_id,
            sender_id,
            saved_message
          )
        end)

        {:reply, {:ok, saved_message}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("message:edit", %{"messageId" => message_id, "content" => content}, socket) do
    user_id = socket.assigns.user_id

    case edit_message(message_id, user_id, content) do
      {:ok, updated_message} ->
        broadcast!(socket, "message:edited", updated_message)
        {:reply, {:ok, updated_message}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("message:delete", %{"messageId" => message_id}, socket) do
    user_id = socket.assigns.user_id
    conversation_id = socket.assigns[:conversation_id]

    case delete_message(message_id, user_id) do
      :ok ->
        broadcast!(socket, "message:deleted", %{
          message_id: message_id,
          conversation_id: conversation_id
        })
        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  # ================== REACTION HANDLERS ==================

  def handle_in("message:reaction:add", payload, socket) do
    # Use external_id (MongoDB ObjectId) for reactions
    external_id = socket.assigns[:external_id] || socket.assigns.user_id
    message_id = payload["messageId"]
    emoji = payload["emoji"]
    conversation_id = payload["conversationId"] || socket.assigns[:conversation_id]

    case add_reaction(message_id, external_id, emoji) do
      :ok ->
        broadcast!(socket, "message:reaction:added", %{
          message_id: message_id,
          user_id: external_id,
          emoji: emoji,
          conversation_id: conversation_id
        })
        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("message:reaction:remove", payload, socket) do
    # Use external_id (MongoDB ObjectId) for reactions
    external_id = socket.assigns[:external_id] || socket.assigns.user_id
    message_id = payload["messageId"]
    emoji = payload["emoji"]
    conversation_id = payload["conversationId"] || socket.assigns[:conversation_id]

    case remove_reaction(message_id, external_id, emoji) do
      :ok ->
        broadcast!(socket, "message:reaction:removed", %{
          message_id: message_id,
          user_id: external_id,
          emoji: emoji,
          conversation_id: conversation_id
        })
        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  # ================== TYPING INDICATORS ==================

  def handle_in("typing:start", %{"conversationId" => conversation_id}, socket) do
    user_id = socket.assigns.user_id

    broadcast_from!(socket, "typing:start", %{
      conversation_id: conversation_id,
      user_id: user_id
    })

    {:noreply, socket}
  end

  def handle_in("typing:stop", %{"conversationId" => conversation_id}, socket) do
    user_id = socket.assigns.user_id

    broadcast_from!(socket, "typing:stop", %{
      conversation_id: conversation_id,
      user_id: user_id
    })

    {:noreply, socket}
  end

  # ================== READ RECEIPTS ==================

  def handle_in("message:read", payload, socket) do
    # Use external_id (MongoDB ObjectId) for read receipts
    external_id = socket.assigns[:external_id] || socket.assigns.user_id
    message_id = payload["messageId"]
    conversation_id = payload["conversationId"] || socket.assigns[:conversation_id]

    case mark_as_read(conversation_id, external_id, message_id) do
      :ok ->
        broadcast!(socket, "message:read", %{
          message_id: message_id,
          user_id: external_id,
          conversation_id: conversation_id
        })
        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  # ================== CONVERSATION MANAGEMENT ==================

  def handle_in("conversation:join", %{"conversationId" => conversation_id}, socket) do
    # Subscribe to the conversation topic
    Phoenix.PubSub.subscribe(QuckAppRealtime.PubSub, "conversation:#{conversation_id}")
    {:reply, :ok, assign(socket, :conversation_id, conversation_id)}
  end

  def handle_in("conversation:leave", %{"conversationId" => conversation_id}, socket) do
    Phoenix.PubSub.unsubscribe(QuckAppRealtime.PubSub, "conversation:#{conversation_id}")
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
    # Only broadcast if socket has successfully joined (has a conversation_id)
    if socket.assigns[:conversation_id] do
      user_id = socket.assigns.user_id
      Presence.untrack_user(socket, user_id)

      # Broadcast offline status - use try/catch to avoid crash on failed joins
      try do
        broadcast!(socket, "user:offline", %{user_id: user_id})
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  # ================== PRIVATE FUNCTIONS ==================

  # Simplified verification - just check conversation exists
  # TODO: Re-enable strict participant verification once user ID mapping is fixed
  defp verify_conversation_exists(conversation_id) do
    case Mongo.find_conversation(conversation_id) do
      {:ok, _conversation} ->
        :ok

      {:error, :not_found} ->
        {:error, "conversation_not_found"}

      _ ->
        {:error, "database_error"}
    end
  end

  # Full verification (disabled for now due to user ID format mismatch)
  defp _verify_conversation_access(user_id, conversation_id) do
    case Mongo.find_conversation(conversation_id) do
      {:ok, conversation} ->
        participants = conversation["participants"] || []
        user_ids = Enum.map(participants, & &1["userId"] |> to_string())

        if user_id in user_ids do
          :ok
        else
          {:error, "not_a_participant"}
        end

      {:error, :not_found} ->
        {:error, "conversation_not_found"}

      _ ->
        {:error, "database_error"}
    end
  end

  defp create_message(message) do
    # In production, call NestJS API via HTTP
    # For now, insert directly into MongoDB
    # Note: sender_id may be a UUID (from auth-service) or MongoDB ObjectId
    # Store as string since we can't guarantee format
    mongo_message = %{
      "conversationId" => safe_decode_object_id(message.conversation_id),
      "senderId" => message.sender_id,  # Store as string (UUID format)
      "type" => message.type,
      "content" => message.content,
      "attachments" => message.attachments,
      "replyTo" => message.reply_to && safe_decode_object_id(message.reply_to),
      "isForwarded" => message.is_forwarded,
      "forwardedFrom" => message.forwarded_from,
      "reactions" => [],
      "readBy" => [],
      "createdAt" => message.created_at,
      "updatedAt" => message.updated_at
    }

    case Mongo.insert_message(mongo_message) do
      {:ok, id} ->
        {:ok, Map.put(message, :id, BSON.ObjectId.encode!(id))}

      error ->
        Logger.error("Failed to create message: #{inspect(error)}")
        {:error, "failed_to_create_message"}
    end
  end

  defp edit_message(message_id, user_id, content) do
    updates = %{
      "content" => content,
      "isEdited" => true,
      "updatedAt" => DateTime.utc_now()
    }

    case Mongo.update_message(message_id, updates) do
      {:ok, _} ->
        {:ok, %{id: message_id, content: content, is_edited: true}}

      error ->
        Logger.error("Failed to edit message: #{inspect(error)}")
        {:error, "failed_to_edit_message"}
    end
  end

  defp delete_message(message_id, _user_id) do
    updates = %{
      "isDeleted" => true,
      "deletedAt" => DateTime.utc_now()
    }

    case Mongo.update_message(message_id, updates) do
      {:ok, _} -> :ok
      error ->
        Logger.error("Failed to delete message: #{inspect(error)}")
        {:error, "failed_to_delete_message"}
    end
  end

  defp add_reaction(message_id, user_id, emoji) do
    # This would update the reactions array in MongoDB
    # For now, just return success
    Logger.info("Adding reaction #{emoji} by #{user_id} to message #{message_id}")
    :ok
  end

  defp remove_reaction(message_id, user_id, emoji) do
    Logger.info("Removing reaction #{emoji} by #{user_id} from message #{message_id}")
    :ok
  end

  defp mark_as_read(conversation_id, user_id, message_id) do
    Logger.info("Marking message #{message_id} as read by #{user_id} in #{conversation_id}")
    :ok
  end

  # Safely decode a string to BSON ObjectId
  # Returns the ObjectId if valid, otherwise returns the string as-is
  defp safe_decode_object_id(nil), do: nil
  defp safe_decode_object_id(id) when is_binary(id) do
    # MongoDB ObjectId is 24 hex characters
    if String.match?(id, ~r/^[a-fA-F0-9]{24}$/) do
      BSON.ObjectId.decode!(id)
    else
      # Not a valid ObjectId format (e.g., UUID), store as string
      id
    end
  end
  defp safe_decode_object_id(id), do: id
end
