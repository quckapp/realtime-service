defmodule QuckAppRealtime.MessageRouter do
  @moduledoc """
  WhatsApp-Style Message Router.

  Routes messages between users:
  1. If recipient is online → deliver immediately
  2. If recipient is offline → store in queue (Store-and-Forward)
  3. Group messages → fan out to all participants

  This is the heart of the messaging system.
  """
  require Logger

  alias QuckAppRealtime.{StoreAndForward, PresenceManager, NestJSClient}
  alias QuckAppRealtime.Actors.UserSession

  @doc """
  Route a message from sender to recipient(s).

  Message format:
  %{
    id: "msg_xxx",
    conversation_id: "conv_xxx",
    sender_id: "user_xxx",
    recipient_ids: ["user_yyy", "user_zzz"],  # For group, multiple recipients
    type: "text",
    content: "Hello",
    metadata: %{},
    timestamp: DateTime
  }
  """
  def route(message, sender_id) do
    message = normalize_message(message, sender_id)

    # Persist message to NestJS/MongoDB first
    case persist_message(message) do
      {:ok, persisted_message} ->
        # Route to recipients
        route_to_recipients(persisted_message)

      {:error, reason} ->
        Logger.error("Failed to persist message: #{inspect(reason)}")
        {:error, :persistence_failed}
    end
  end

  @doc """
  Route a real-time event (typing, presence, etc.) - no persistence needed.
  """
  def route_event(event, recipient_ids) do
    Enum.each(recipient_ids, fn recipient_id ->
      if UserSession.online?(recipient_id) do
        UserSession.send_message(recipient_id, event)
      end
    end)

    :ok
  end

  @doc """
  Route a call signaling message.
  """
  def route_call_signal(signal, from_user_id, to_user_id) do
    signal = Map.put(signal, :from, from_user_id)

    if UserSession.online?(to_user_id) do
      UserSession.send_message(to_user_id, signal)
      :ok
    else
      {:error, :user_offline}
    end
  end

  # ============================================
  # Private Functions
  # ============================================

  defp normalize_message(message, sender_id) do
    message
    |> Map.put(:sender_id, sender_id)
    |> Map.put_new(:id, generate_message_id())
    |> Map.put_new(:timestamp, DateTime.utc_now())
    |> ensure_recipient_ids()
  end

  defp ensure_recipient_ids(message) do
    cond do
      Map.has_key?(message, :recipient_ids) ->
        message

      Map.has_key?(message, :recipient_id) ->
        Map.put(message, :recipient_ids, [message.recipient_id])

      Map.has_key?(message, :conversation_id) ->
        # Fetch participants from conversation
        case get_conversation_participants(message.conversation_id, message.sender_id) do
          {:ok, participants} ->
            Map.put(message, :recipient_ids, participants)

          {:error, _} ->
            Map.put(message, :recipient_ids, [])
        end

      true ->
        Map.put(message, :recipient_ids, [])
    end
  end

  defp persist_message(message) do
    # Persist to NestJS/MongoDB
    case NestJSClient.create_message(
      message.conversation_id,
      message.sender_id,
      message[:type] || "text",
      message[:content],
      Map.take(message, [:attachments, :reply_to, :metadata])
    ) do
      {:ok, %{"data" => data}} ->
        {:ok, Map.merge(message, %{id: data["_id"]})}

      {:ok, data} when is_map(data) ->
        {:ok, Map.merge(message, %{id: data["_id"] || data["id"]})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp route_to_recipients(message) do
    recipient_ids = message[:recipient_ids] || []
    sender_id = message.sender_id

    results = Enum.map(recipient_ids, fn recipient_id ->
      # Don't send back to sender
      if recipient_id != sender_id do
        route_to_single_recipient(message, recipient_id)
      else
        {:ok, :skipped}
      end
    end)

    # Check if any messages were queued
    queued = Enum.any?(results, fn
      {:queued, _} -> true
      _ -> false
    end)

    if queued do
      {:queued, Enum.find_value(results, fn
        {:queued, id} -> id
        _ -> nil
      end)}
    else
      :ok
    end
  end

  defp route_to_single_recipient(message, recipient_id) do
    if UserSession.online?(recipient_id) do
      # User is online - deliver immediately
      UserSession.send_message(recipient_id, format_outgoing_message(message))
      {:ok, :delivered}
    else
      # User is offline - store for later delivery
      queue_for_offline_delivery(message, recipient_id)
      {:queued, recipient_id}
    end
  end

  defp queue_for_offline_delivery(message, recipient_id) do
    StoreAndForward.queue_message(%{
      message_id: message[:id] || message["id"],
      conversation_id: message.conversation_id,
      sender_id: message.sender_id,
      recipient_id: recipient_id,
      message_type: message[:type] || "text",
      content: message[:content],
      metadata: message[:metadata] || %{},
      priority: get_message_priority(message)
    })
  end

  defp format_outgoing_message(message) do
    %{
      type: "message:new",
      data: %{
        id: message[:id],
        conversation_id: message.conversation_id,
        sender_id: message.sender_id,
        type: message[:type] || "text",
        content: message[:content],
        metadata: message[:metadata] || %{},
        timestamp: message[:timestamp] || DateTime.utc_now()
      }
    }
  end

  defp get_conversation_participants(conversation_id, exclude_user_id) do
    case NestJSClient.get_conversation_participants(conversation_id) do
      {:ok, %{"data" => participants}} ->
        ids = participants
          |> Enum.map(&(&1["userId"] || &1["user_id"]))
          |> Enum.reject(&(&1 == exclude_user_id))
        {:ok, ids}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_message_priority(message) do
    case message[:type] do
      "call" -> 10
      "system" -> 5
      _ -> 0
    end
  end

  defp generate_message_id do
    "msg_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
  end
end
