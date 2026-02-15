defmodule QuckAppRealtime.Kafka.Consumer do
  @moduledoc """
  Kafka Consumer for receiving events from NestJS backend and other services.

  ## Design Patterns Used:
  - **Circuit Breaker**: Graceful degradation when Kafka is unavailable
  - **Strategy Pattern**: Event handlers for different event types
  - **Observer Pattern**: PubSub notifications for real-time updates
  - **Router Pattern**: Topic-based message routing

  ## Data Structures:
  - ETS table for deduplication with TTL
  - ETS table for connection tracking
  - User session registry for efficient lookups

  Subscribes to topics:
  - quckapp.backend.messages     - Message events from NestJS
  - quckapp.backend.users        - User events (profile updates, etc.)
  - quckapp.backend.conversations - Conversation events
  - quckapp.backend.notifications - Push notification requests
  """
  use GenServer
  require Logger

  alias QuckAppRealtime.Actors.UserSession

  # Valid event types - prevents atom table exhaustion
  @valid_message_types ~w(text image video audio file location sticker)
  @valid_user_statuses ~w(online offline away busy dnd invisible)

  # Circuit breaker configuration
  @max_failures 5
  @reset_timeout_ms 30_000
  @retry_delay_ms 5_000

  # Deduplication window
  @dedup_window_ms 60_000

  # Topics to subscribe
  @subscribed_topics [
    "quckapp.backend.messages",
    "quckapp.backend.users",
    "quckapp.backend.conversations",
    "quckapp.backend.notifications"
  ]

  defstruct [
    :consumer_pid,
    :brokers,
    :group_id,
    :topics,
    :circuit_state,
    :failure_count,
    :last_failure_at,
    enabled: false
  ]

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Check if consumer is healthy"
  def healthy? do
    GenServer.call(__MODULE__, :health_check)
  catch
    :exit, _ -> false
  end

  @doc "Get consumer statistics"
  def stats do
    GenServer.call(__MODULE__, :stats)
  catch
    :exit, _ -> %{status: :unavailable}
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Initialize ETS tables
    :ets.new(:realtime_kafka_dedup, [:set, :named_table, :public])
    :ets.new(:realtime_kafka_stats, [:set, :named_table, :public])
    init_stats()

    config = Application.get_env(:quckapp_realtime, :kafka, [])
    enabled = config[:enabled] || System.get_env("KAFKA_ENABLED") == "true"

    state = %__MODULE__{
      circuit_state: :closed,
      failure_count: 0,
      last_failure_at: nil,
      enabled: enabled
    }

    if enabled do
      send(self(), :connect)
    else
      Logger.info("[RealtimeKafkaConsumer] Kafka disabled - running without event streaming")
    end

    schedule_cleanup()

    {:ok, state}
  end

  @impl true
  def handle_info(:connect, %{enabled: false} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect_to_kafka(state) do
      {:ok, new_state} ->
        Logger.info("[RealtimeKafkaConsumer] Successfully connected to Kafka")
        {:noreply, %{new_state | circuit_state: :closed, failure_count: 0}}

      {:error, reason} ->
        new_state = handle_connection_failure(state, reason)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(:retry_connect, state) do
    if state.circuit_state == :open do
      if should_attempt_reset?(state) do
        Logger.info("[RealtimeKafkaConsumer] Circuit half-open, attempting reconnect")
        send(self(), :connect)
        {:noreply, %{state | circuit_state: :half_open}}
      else
        schedule_retry()
        {:noreply, state}
      end
    else
      send(self(), :connect)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:cleanup_dedup, state) do
    cutoff = System.system_time(:millisecond) - @dedup_window_ms

    :ets.select_delete(:realtime_kafka_dedup, [
      {{:"$1", :"$2"}, [{:<, :"$2", cutoff}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info({:kafka_message, topic, partition, offset, key, value}, state) do
    Logger.debug("[RealtimeKafkaConsumer] Kafka message received: #{topic} [#{partition}:#{offset}]")

    message_id = "#{topic}-#{partition}-#{offset}"

    unless is_duplicate?(message_id) do
      case Jason.decode(value) do
        {:ok, event} ->
          handle_event(topic, key, event)
          mark_processed(message_id)
          increment_stat(:messages_processed)

        {:error, reason} ->
          Logger.error("[RealtimeKafkaConsumer] Failed to decode Kafka message: #{inspect(reason)}")
          increment_stat(:messages_failed)
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{consumer_pid: pid} = state) do
    Logger.warning("[RealtimeKafkaConsumer] Consumer process died: #{inspect(reason)}")
    new_state = handle_connection_failure(state, reason)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[RealtimeKafkaConsumer] Received: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:health_check, _from, state) do
    healthy = state.circuit_state == :closed and (state.consumer_pid != nil or not state.enabled)
    {:reply, healthy, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      circuit_state: state.circuit_state,
      failure_count: state.failure_count,
      consumer_connected: state.consumer_pid != nil,
      dedup_size: :ets.info(:realtime_kafka_dedup, :size),
      messages_processed: get_stat(:messages_processed),
      messages_failed: get_stat(:messages_failed),
      enabled: state.enabled
    }
    {:reply, stats, state}
  end

  # ============================================================================
  # Brod Callbacks - Group Subscriber
  # ============================================================================

  @doc "brod_group_subscriber callback - called when subscriber initializes"
  def init(_group_id, _init_args) do
    {:ok, %{}}
  end

  def handle_message(topic, partition, message, state) do
    message_id = extract_message_id(message)

    cond do
      is_duplicate?(message_id) ->
        Logger.debug("[RealtimeKafkaConsumer] Skipping duplicate message: #{message_id}")
        {:ok, :ack, state}

      true ->
        result = safe_process_message(topic, partition, message)
        mark_processed(message_id)

        case result do
          :ok ->
            increment_stat(:messages_processed)
            {:ok, :ack, state}

          {:error, :retriable} ->
            {:ok, :ack_no_commit, state}

          {:error, _} ->
            increment_stat(:messages_failed)
            {:ok, :ack, state}
        end
    end
  end

  # ============================================================================
  # Private Functions - Connection Management
  # ============================================================================

  defp connect_to_kafka(state) do
    config = Application.get_env(:quckapp_realtime, :kafka, [])

    brokers = parse_brokers(config[:brokers] || System.get_env("KAFKA_BROKERS") || "localhost:9092")
    group_id = config[:consumer_group] || System.get_env("KAFKA_CONSUMER_GROUP") || "quckapp-realtime-group"
    client_id = :realtime_consumer

    Logger.info("[RealtimeKafkaConsumer] Connecting to brokers: #{inspect(brokers)}, group: #{group_id}")

    # Start brod client first (required before starting group subscriber)
    case :brod.start_client(brokers, client_id, []) do
      :ok ->
        start_group_subscriber(state, client_id, brokers, group_id)

      {:error, {:already_started, _pid}} ->
        start_group_subscriber(state, client_id, brokers, group_id)

      {:error, reason} ->
        Logger.error("[RealtimeKafkaConsumer] Failed to start brod client: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp start_group_subscriber(state, client_id, brokers, group_id) do
    group_config = [
      offset_commit_policy: :commit_to_kafka_v2,
      offset_commit_interval_seconds: 5,
      rejoin_delay_seconds: 2
    ]

    consumer_config = [begin_offset: :earliest]

    case :brod.start_link_group_subscriber(
           client_id,
           group_id,
           @subscribed_topics,
           group_config,
           consumer_config,
           __MODULE__,
           []
         ) do
      {:ok, pid} ->
        Process.monitor(pid)
        {:ok, %{state | consumer_pid: pid, brokers: brokers, group_id: group_id, topics: @subscribed_topics}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_brokers(brokers) when is_binary(brokers) do
    brokers
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&parse_single_broker/1)
  end

  defp parse_brokers(brokers) when is_list(brokers) do
    Enum.map(brokers, fn
      {host, port} when is_list(host) -> {host, port}
      {host, port} when is_binary(host) -> {String.to_charlist(host), port}
      broker when is_binary(broker) -> parse_single_broker(broker)
    end)
  end

  defp parse_single_broker(broker) do
    case String.split(broker, ":") do
      [host, port] -> {String.to_charlist(host), String.to_integer(port)}
      [host] -> {String.to_charlist(host), 9092}
    end
  end

  # ============================================================================
  # Private Functions - Circuit Breaker
  # ============================================================================

  defp handle_connection_failure(state, reason) do
    new_failure_count = state.failure_count + 1
    Logger.warning("[RealtimeKafkaConsumer] Connection failed (#{new_failure_count}/#{@max_failures}): #{inspect(reason)}")

    new_state = %{state |
      failure_count: new_failure_count,
      last_failure_at: System.system_time(:millisecond),
      consumer_pid: nil
    }

    if new_failure_count >= @max_failures do
      Logger.error("[RealtimeKafkaConsumer] Circuit breaker OPEN - max failures reached")
      schedule_retry()
      %{new_state | circuit_state: :open}
    else
      schedule_retry()
      new_state
    end
  end

  defp should_attempt_reset?(state) do
    case state.last_failure_at do
      nil -> true
      last_failure ->
        elapsed = System.system_time(:millisecond) - last_failure
        elapsed >= @reset_timeout_ms
    end
  end

  defp schedule_retry, do: Process.send_after(self(), :retry_connect, @retry_delay_ms)
  defp schedule_cleanup, do: Process.send_after(self(), :cleanup_dedup, @dedup_window_ms)

  # ============================================================================
  # Private Functions - Message Processing
  # ============================================================================

  defp safe_process_message(topic, _partition, message) do
    with {:ok, payload} <- extract_payload(message),
         {:ok, event} <- Jason.decode(payload) do
      handle_event(topic, nil, event)
      :telemetry.execute(
        [:quckapp_realtime, :kafka, :message_processed],
        %{count: 1},
        %{topic: topic}
      )
      :ok
    else
      {:error, :invalid_json} ->
        Logger.warning("[RealtimeKafkaConsumer] Invalid JSON in message")
        {:error, :invalid_json}

      {:error, reason} ->
        Logger.error("[RealtimeKafkaConsumer] Error processing message: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp extract_payload(message) when is_map(message), do: {:ok, message.value}
  defp extract_payload(message) when is_tuple(message), do: {:ok, elem(message, 4)}
  defp extract_payload(_), do: {:error, :invalid_message_format}

  defp extract_message_id(message) do
    case message do
      %{key: key} when is_binary(key) -> key
      %{offset: offset, partition: partition} -> "#{partition}-#{offset}"
      tuple when is_tuple(tuple) -> "#{elem(tuple, 1)}-#{elem(tuple, 2)}"
      _ -> :crypto.strong_rand_bytes(16) |> Base.encode16()
    end
  end

  # ============================================================================
  # Event Handlers (Strategy Pattern / Router Pattern)
  # ============================================================================

  defp handle_event("quckapp.backend.messages", _key, event) do
    case event["event_type"] do
      "message.created" ->
        handle_message_created(event["data"])

      "message.updated" ->
        handle_message_updated(event["data"])

      "message.deleted" ->
        handle_message_deleted(event["data"])

      _ ->
        Logger.debug("[RealtimeKafkaConsumer] Unknown message event: #{event["event_type"]}")
    end
    :ok
  end

  defp handle_event("quckapp.backend.users", _key, event) do
    case event["event_type"] do
      "user.updated" ->
        handle_user_updated(event["data"])

      "user.blocked" ->
        handle_user_blocked(event["data"])

      "user.status_changed" ->
        handle_user_status_changed(event["data"])

      _ ->
        Logger.debug("[RealtimeKafkaConsumer] Unknown user event: #{event["event_type"]}")
    end
    :ok
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
        Logger.debug("[RealtimeKafkaConsumer] Unknown conversation event: #{event["event_type"]}")
    end
    :ok
  end

  defp handle_event("quckapp.backend.notifications", _key, event) do
    case event["event_type"] do
      "notification.push" ->
        handle_push_notification(event["data"])

      _ ->
        Logger.debug("[RealtimeKafkaConsumer] Unknown notification event: #{event["event_type"]}")
    end
    :ok
  end

  defp handle_event(topic, _key, event) do
    Logger.debug("[RealtimeKafkaConsumer] Unhandled topic #{topic}: #{inspect(event)}")
    :ok
  end

  # ============================================================================
  # Message Handlers
  # ============================================================================

  defp handle_message_created(data) do
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

    Task.start(fn ->
      Enum.each(recipient_ids, fn user_id ->
        send_to_user_if_online(user_id, message)
      end)
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

  # ============================================================================
  # User Handlers
  # ============================================================================

  defp handle_user_updated(data) do
    user_id = data["userId"]

    message = %{
      type: "user:updated",
      data: %{
        user_id: user_id,
        changes: data["changes"]
      }
    }

    send_to_user_if_online(user_id, %{type: "profile:sync", data: data["changes"]})

    # Broadcast to contacts
    broadcast_to_user_contacts(user_id, message)
  end

  defp handle_user_blocked(data) do
    blocker_id = data["blockerId"]
    blocked_id = data["blockedId"]

    send_to_user_if_online(blocked_id, %{
      type: "user:blocked",
      data: %{blocked_by: blocker_id}
    })
  end

  defp handle_user_status_changed(data) do
    user_id = data["userId"]
    status = data["status"]

    with {:ok, _status_atom} <- validate_status(status) do
      message = %{
        type: "user:status_changed",
        data: %{user_id: user_id, status: status}
      }

      broadcast_to_user_contacts(user_id, message)
    end
  end

  # ============================================================================
  # Conversation Handlers
  # ============================================================================

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

    Task.start(fn ->
      Enum.each(participant_ids, fn user_id ->
        send_to_user_if_online(user_id, message)
      end)
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

    # Notify added user
    send_to_user_if_online(data["userId"], %{
      type: "conversation:joined",
      data: %{conversation_id: data["conversationId"]}
    })
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

  # ============================================================================
  # Notification Handlers
  # ============================================================================

  defp handle_push_notification(data) do
    user_ids = data["userIds"] || []

    Task.start(fn ->
      Enum.each(user_ids, fn user_id ->
        send_to_user_if_online(user_id, %{
          type: "notification",
          data: %{
            title: data["title"],
            body: data["body"],
            data: data["data"]
          }
        })
      end)
    end)
  end

  # ============================================================================
  # Private Functions - Broadcasting
  # ============================================================================

  defp send_to_user_if_online(user_id, message) do
    if user_online?(user_id) do
      UserSession.send_message(user_id, message)
    end
  rescue
    _ -> :ok
  end

  defp user_online?(user_id) do
    UserSession.online?(user_id)
  rescue
    _ -> false
  end

  defp broadcast_to_conversation(conversation_id, message) do
    Phoenix.PubSub.broadcast(
      QuckAppRealtime.PubSub,
      "conversation:#{conversation_id}",
      {:kafka_event, message}
    )
  end

  defp broadcast_to_user_contacts(_user_id, _message) do
    # Simplified - in production would look up contacts
    :ok
  end

  # ============================================================================
  # Private Functions - Validation
  # ============================================================================

  defp validate_status(status) when status in @valid_user_statuses do
    {:ok, String.to_existing_atom(status)}
  rescue
    ArgumentError -> {:error, :invalid_status}
  end

  defp validate_status(_status), do: {:error, :invalid_status}

  # ============================================================================
  # Private Functions - Deduplication & Stats
  # ============================================================================

  defp is_duplicate?(message_id) do
    case :ets.lookup(:realtime_kafka_dedup, message_id) do
      [{^message_id, _timestamp}] -> true
      [] -> false
    end
  end

  defp mark_processed(message_id) do
    timestamp = System.system_time(:millisecond)
    :ets.insert(:realtime_kafka_dedup, {message_id, timestamp})
  end

  defp init_stats do
    :ets.insert(:realtime_kafka_stats, {:messages_processed, 0})
    :ets.insert(:realtime_kafka_stats, {:messages_failed, 0})
  end

  defp get_stat(key) do
    case :ets.lookup(:realtime_kafka_stats, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  end

  defp increment_stat(key) do
    :ets.update_counter(:realtime_kafka_stats, key, 1)
  rescue
    _ -> :ok
  end
end
