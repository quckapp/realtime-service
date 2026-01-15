defmodule QuckAppRealtime.Kafka.Consumer do
  @moduledoc """
  Kafka Consumer for receiving events from NestJS backend.

  Subscribes to topics:
  - quckapp.backend.messages     - Message events from NestJS
  - quckapp.backend.users        - User events (profile updates, etc.)
  - quckapp.backend.conversations - Conversation events
  - quckapp.backend.notifications - Push notification requests
  """

  use GenServer
  require Logger

  alias QuckAppRealtime.{MessageRouter, PresenceManager}
  alias QuckAppRealtime.Actors.UserSession

  @client_id :quckapp_kafka_consumer
  @group_id "quckapp-realtime-group"

  # Topics to subscribe
  @subscribed_topics [
    "quckapp.backend.messages",
    "quckapp.backend.users",
    "quckapp.backend.conversations",
    "quckapp.backend.notifications"
  ]

  # ============================================
  # Client API
  # ============================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ============================================
  # GenServer Callbacks
  # ============================================

  @impl true
  def init(_opts) do
    config = Application.get_env(:quckapp_realtime, :kafka, [])
    brokers = Keyword.get(config, :brokers, [{"localhost", 9092}])
    enabled = Keyword.get(config, :enabled, false)

    if enabled do
      case start_kafka_consumer(brokers) do
        :ok ->
          Logger.info("Kafka consumer started successfully")
          {:ok, %{enabled: true, brokers: brokers}}

        {:error, reason} ->
          Logger.warning("Kafka consumer failed to start: #{inspect(reason)}")
          {:ok, %{enabled: false, brokers: brokers}}
      end
    else
      Logger.info("Kafka consumer disabled")
      {:ok, %{enabled: false, brokers: brokers}}
    end
  end

  @impl true
  def handle_info({:kafka_message, topic, partition, offset, key, value}, state) do
    Logger.debug("Kafka message received: #{topic} [#{partition}:#{offset}]")

    case Jason.decode(value) do
      {:ok, event} ->
        handle_event(topic, key, event)

      {:error, reason} ->
        Logger.error("Failed to decode Kafka message: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Kafka consumer received: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================
  # Event Handlers
  # ============================================

  defp handle_event("quckapp.backend.messages", _key, event) do
    case event["event_type"] do
      "message.created" ->
        handle_message_created(event["data"])

      "message.updated" ->
        handle_message_updated(event["data"])

      "message.deleted" ->
        handle_message_deleted(event["data"])

      _ ->
        Logger.debug("Unknown message event: #{event["event_type"]}")
    end
  end

  defp handle_event("quckapp.backend.users", _key, event) do
    case event["event_type"] do
      "user.updated" ->
        handle_user_updated(event["data"])

      "user.blocked" ->
        handle_user_blocked(event["data"])

      _ ->
        Logger.debug("Unknown user event: #{event["event_type"]}")
    end
  end

  defp handle_event("quckapp.backend.conversations", _key, event) do
    case event["event_type"] do
      "conversation.created" ->
        handle_conversation_created(event["data"])

      "conversation.updated" ->
        handle_conversation_updated(event["data"])

      "participant.added" ->
        handle_participant_added(event["data"])

      "participant.removed" ->
        handle_participant_removed(event["data"])

      _ ->
        Logger.debug("Unknown conversation event: #{event["event_type"]}")
    end
  end

  defp handle_event("quckapp.backend.notifications", _key, event) do
    case event["event_type"] do
      "notification.push" ->
        handle_push_notification(event["data"])

      _ ->
        Logger.debug("Unknown notification event: #{event["event_type"]}")
    end
  end

  defp handle_event(topic, _key, event) do
    Logger.debug("Unhandled topic #{topic}: #{inspect(event)}")
  end

  # ============================================
  # Message Handlers
  # ============================================

  defp handle_message_created(data) do
    # Route message to online users
    recipient_ids = data["recipientIds"] || []

    message = %{
      type: "message:new",
      data: %{
        id: data["messageId"],
        conversation_id: data["conversationId"],
        sender_id: data["senderId"],
        type: data["type"],
        content: data["content"],
        metadata: data["metadata"] || %{},
        timestamp: data["timestamp"]
      }
    }

    Enum.each(recipient_ids, fn user_id ->
      if UserSession.online?(user_id) do
        UserSession.send_message(user_id, message)
      end
    end)
  end

  defp handle_message_updated(data) do
    message = %{
      type: "message:updated",
      data: %{
        id: data["messageId"],
        conversation_id: data["conversationId"],
        content: data["content"],
        edited_at: data["editedAt"]
      }
    }

    broadcast_to_conversation(data["conversationId"], message)
  end

  defp handle_message_deleted(data) do
    message = %{
      type: "message:deleted",
      data: %{
        id: data["messageId"],
        conversation_id: data["conversationId"],
        deleted_by: data["deletedBy"]
      }
    }

    broadcast_to_conversation(data["conversationId"], message)
  end

  # ============================================
  # User Handlers
  # ============================================

  defp handle_user_updated(data) do
    # Notify user's contacts about profile update
    user_id = data["userId"]

    message = %{
      type: "user:updated",
      data: %{
        user_id: user_id,
        changes: data["changes"]
      }
    }

    # Broadcast to user's conversations
    if UserSession.online?(user_id) do
      UserSession.send_message(user_id, %{type: "profile:sync", data: data["changes"]})
    end
  end

  defp handle_user_blocked(data) do
    blocker_id = data["blockerId"]
    blocked_id = data["blockedId"]

    # Notify blocked user if online
    if UserSession.online?(blocked_id) do
      UserSession.send_message(blocked_id, %{
        type: "user:blocked",
        data: %{blocked_by: blocker_id}
      })
    end
  end

  # ============================================
  # Conversation Handlers
  # ============================================

  defp handle_conversation_created(data) do
    participant_ids = data["participantIds"] || []

    message = %{
      type: "conversation:created",
      data: %{
        conversation_id: data["conversationId"],
        type: data["type"],
        name: data["name"],
        participants: data["participants"]
      }
    }

    Enum.each(participant_ids, fn user_id ->
      if UserSession.online?(user_id) do
        UserSession.send_message(user_id, message)
      end
    end)
  end

  defp handle_conversation_updated(data) do
    message = %{
      type: "conversation:updated",
      data: data
    }

    broadcast_to_conversation(data["conversationId"], message)
  end

  defp handle_participant_added(data) do
    message = %{
      type: "conversation:participant_added",
      data: %{
        conversation_id: data["conversationId"],
        user_id: data["userId"],
        added_by: data["addedBy"]
      }
    }

    broadcast_to_conversation(data["conversationId"], message)

    # Also notify the added user
    if UserSession.online?(data["userId"]) do
      UserSession.send_message(data["userId"], %{
        type: "conversation:joined",
        data: %{conversation_id: data["conversationId"]}
      })
    end
  end

  defp handle_participant_removed(data) do
    message = %{
      type: "conversation:participant_removed",
      data: %{
        conversation_id: data["conversationId"],
        user_id: data["userId"],
        removed_by: data["removedBy"]
      }
    }

    broadcast_to_conversation(data["conversationId"], message)
  end

  # ============================================
  # Notification Handlers
  # ============================================

  defp handle_push_notification(data) do
    user_ids = data["userIds"] || []

    # For online users, send via WebSocket instead of push
    Enum.each(user_ids, fn user_id ->
      if UserSession.online?(user_id) do
        UserSession.send_message(user_id, %{
          type: "notification",
          data: %{
            title: data["title"],
            body: data["body"],
            data: data["data"]
          }
        })
      end
    end)
  end

  # ============================================
  # Private Functions
  # ============================================

  defp start_kafka_consumer(brokers) do
    # Start brod client
    case :brod.start_client(brokers, @client_id, []) do
      :ok ->
        # Subscribe to topics
        Enum.each(@subscribed_topics, fn topic ->
          :brod.start_link_group_subscriber(
            @client_id,
            @group_id,
            [topic],
            _config = [],
            _callback_module = __MODULE__,
            _callback_init_args = []
          )
        end)
        :ok

      error ->
        error
    end
  end

  defp broadcast_to_conversation(conversation_id, message) do
    Phoenix.PubSub.broadcast(
      QuckAppRealtime.PubSub,
      "conversation:#{conversation_id}",
      {:kafka_event, message}
    )
  end

  # Brod group subscriber callbacks
  def init(_group_id, _callback_init_args) do
    {:ok, %{}}
  end

  def handle_message(_topic, _partition, message, state) do
    send(self(), {:kafka_message,
      message.topic,
      message.partition,
      message.offset,
      message.key,
      message.value
    })
    {:ok, :ack, state}
  end
end
