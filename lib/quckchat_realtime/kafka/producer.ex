defmodule QuckAppRealtime.Kafka.Producer do
  @moduledoc """
  Kafka Producer for publishing events.

  Topics:
  - quckapp.messages.created    - New messages
  - quckapp.messages.delivered  - Message delivery confirmations
  - quckapp.messages.read       - Message read receipts
  - quckapp.calls.events        - Call lifecycle events
  - quckapp.presence.events     - User presence changes
  - quckapp.typing.events       - Typing indicators
  """

  use GenServer
  require Logger

  @client_id :quckapp_kafka_producer

  # Topic names
  @topics %{
    message_created: "quckapp.messages.created",
    message_delivered: "quckapp.messages.delivered",
    message_read: "quckapp.messages.read",
    call_events: "quckapp.calls.events",
    presence_events: "quckapp.presence.events",
    typing_events: "quckapp.typing.events",
    user_events: "quckapp.users.events"
  }

  # ============================================
  # Client API
  # ============================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Publish a message created event"
  def publish_message_created(message) do
    event = %{
      event_type: "message.created",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: %{
        message_id: message[:id] || message["id"],
        conversation_id: message[:conversation_id] || message["conversationId"],
        sender_id: message[:sender_id] || message["senderId"],
        type: message[:type] || message["type"],
        content: message[:content] || message["content"],
        metadata: message[:metadata] || message["metadata"] || %{}
      }
    }

    publish(@topics.message_created, message[:conversation_id], event)
  end

  @doc "Publish message delivered event"
  def publish_message_delivered(message_id, user_id, conversation_id) do
    event = %{
      event_type: "message.delivered",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: %{
        message_id: message_id,
        user_id: user_id,
        conversation_id: conversation_id
      }
    }

    publish(@topics.message_delivered, conversation_id, event)
  end

  @doc "Publish message read event"
  def publish_message_read(message_id, user_id, conversation_id) do
    event = %{
      event_type: "message.read",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: %{
        message_id: message_id,
        user_id: user_id,
        conversation_id: conversation_id
      }
    }

    publish(@topics.message_read, conversation_id, event)
  end

  @doc "Publish call event"
  def publish_call_event(event_type, call) do
    event = %{
      event_type: "call.#{event_type}",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: %{
        call_id: call.call_id,
        conversation_id: call.conversation_id,
        initiator_id: call.initiator_id,
        call_type: call.call_type,
        status: call.status,
        participants: call.participants
      }
    }

    publish(@topics.call_events, call.call_id, event)
  end

  @doc "Publish presence change event"
  def publish_presence_change(user_id, status, last_seen \\ nil) do
    event = %{
      event_type: "presence.changed",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: %{
        user_id: user_id,
        status: status,
        last_seen: last_seen
      }
    }

    publish(@topics.presence_events, user_id, event)
  end

  @doc "Publish typing event"
  def publish_typing(user_id, conversation_id, is_typing) do
    event = %{
      event_type: "typing.#{if is_typing, do: "started", else: "stopped"}",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: %{
        user_id: user_id,
        conversation_id: conversation_id,
        is_typing: is_typing
      }
    }

    publish(@topics.typing_events, conversation_id, event)
  end

  @doc "Publish user event (connect/disconnect)"
  def publish_user_event(event_type, user_id, metadata \\ %{}) do
    event = %{
      event_type: "user.#{event_type}",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: Map.merge(%{user_id: user_id}, metadata)
    }

    publish(@topics.user_events, user_id, event)
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
      case start_kafka_client(brokers) do
        :ok ->
          Logger.info("Kafka producer started successfully")
          {:ok, %{enabled: true, brokers: brokers}}

        {:error, reason} ->
          Logger.warning("Kafka producer failed to start: #{inspect(reason)}")
          {:ok, %{enabled: false, brokers: brokers}}
      end
    else
      Logger.info("Kafka producer disabled")
      {:ok, %{enabled: false, brokers: brokers}}
    end
  end

  @impl true
  def handle_cast({:publish, topic, key, event}, %{enabled: true} = state) do
    do_publish(topic, key, event)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:publish, _topic, _key, _event}, %{enabled: false} = state) do
    # Kafka disabled, skip publishing
    {:noreply, state}
  end

  # ============================================
  # Private Functions
  # ============================================

  defp publish(topic, key, event) do
    GenServer.cast(__MODULE__, {:publish, topic, to_string(key), event})
  end

  defp start_kafka_client(brokers) do
    :brod.start_client(brokers, @client_id, [])
  end

  defp do_publish(topic, key, event) do
    value = Jason.encode!(event)

    case :brod.produce_sync(@client_id, topic, :hash, key, value) do
      :ok ->
        Logger.debug("Published to Kafka: #{topic}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to publish to Kafka #{topic}: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("Kafka publish exception: #{inspect(e)}")
      {:error, e}
  end
end
