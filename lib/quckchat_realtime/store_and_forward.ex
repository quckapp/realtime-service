defmodule QuckAppRealtime.StoreAndForward do
  @moduledoc """
  Store-and-Forward Message Queue - WhatsApp Style.

  When a user is offline, messages are stored in this queue.
  When the user comes online, messages are delivered in order.

  Uses:
  - MySQL for persistent storage (survives restarts)
  - ETS for fast in-memory cache

  Message lifecycle:
  1. Message arrives for offline user → store in queue
  2. User comes online → fetch pending messages
  3. Message delivered → wait for ACK
  4. ACK received → delete from queue
  """
  use GenServer
  require Logger

  alias QuckAppRealtime.Repo
  alias QuckAppRealtime.Schemas.PendingMessage
  import Ecto.Query

  @table_name :pending_messages_cache
  @default_ttl_hours 168  # 7 days
  @batch_size 100

  # ============================================
  # Client API
  # ============================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Queue a message for offline delivery.
  """
  def queue_message(message) do
    GenServer.call(__MODULE__, {:queue, message})
  end

  @doc """
  Get pending messages for a user (when they come online).
  """
  def get_pending_messages(user_id, limit \\ @batch_size) do
    GenServer.call(__MODULE__, {:get_pending, user_id, limit})
  end

  @doc """
  Acknowledge message delivery - remove from queue.
  """
  def ack_message(message_id, user_id) do
    GenServer.cast(__MODULE__, {:ack, message_id, user_id})
  end

  @doc """
  Get count of pending messages for a user.
  """
  def pending_count(user_id) do
    GenServer.call(__MODULE__, {:count, user_id})
  end

  @doc """
  Clear all pending messages for a user (e.g., account deletion).
  """
  def clear_user_messages(user_id) do
    GenServer.call(__MODULE__, {:clear_user, user_id})
  end

  # ============================================
  # Server Callbacks
  # ============================================

  @impl true
  def init(_opts) do
    # Create ETS table for caching
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])

    # Schedule cleanup of expired messages
    schedule_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_call({:queue, message}, _from, state) do
    result = do_queue_message(message)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_pending, user_id, limit}, _from, state) do
    result = do_get_pending(user_id, limit)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:count, user_id}, _from, state) do
    count = do_count_pending(user_id)
    {:reply, count, state}
  end

  @impl true
  def handle_call({:clear_user, user_id}, _from, state) do
    result = do_clear_user(user_id)
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:ack, message_id, user_id}, state) do
    do_ack_message(message_id, user_id)
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup_expired, state) do
    do_cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  # ============================================
  # Private Functions
  # ============================================

  defp do_queue_message(message) do
    expires_at = DateTime.add(DateTime.utc_now(), @default_ttl_hours * 3600, :second)

    attrs = Map.merge(message, %{
      expires_at: expires_at
    })

    case %PendingMessage{} |> PendingMessage.changeset(attrs) |> Repo.insert() do
      {:ok, pending} ->
        # Also cache in ETS for fast access
        cache_message(pending)
        {:ok, pending.id}

      {:error, changeset} ->
        Logger.error("Failed to queue message: #{inspect(changeset.errors)}")
        {:error, changeset.errors}
    end
  end

  defp do_get_pending(user_id, limit) do
    # First try ETS cache
    cached = get_cached_messages(user_id, limit)

    if length(cached) > 0 do
      {:ok, cached}
    else
      # Fallback to database
      messages = PendingMessage
        |> where([m], m.recipient_id == ^user_id)
        |> where([m], m.expires_at > ^DateTime.utc_now())
        |> order_by([m], [asc: m.priority, asc: m.inserted_at])
        |> limit(^limit)
        |> Repo.all()

      # Cache for next time
      Enum.each(messages, &cache_message/1)

      {:ok, format_messages(messages)}
    end
  end

  defp do_count_pending(user_id) do
    PendingMessage
    |> where([m], m.recipient_id == ^user_id)
    |> where([m], m.expires_at > ^DateTime.utc_now())
    |> Repo.aggregate(:count)
  end

  defp do_ack_message(message_id, user_id) do
    # Remove from database
    PendingMessage
    |> where([m], m.message_id == ^message_id and m.recipient_id == ^user_id)
    |> Repo.delete_all()

    # Remove from cache
    :ets.delete(@table_name, {user_id, message_id})

    Logger.debug("Message #{message_id} acknowledged and removed for user #{user_id}")
  end

  defp do_clear_user(user_id) do
    {deleted, _} = PendingMessage
      |> where([m], m.recipient_id == ^user_id)
      |> Repo.delete_all()

    # Clear from cache
    :ets.match_delete(@table_name, {{user_id, :_}, :_})

    {:ok, deleted}
  end

  defp do_cleanup_expired do
    {deleted, _} = PendingMessage
      |> where([m], m.expires_at < ^DateTime.utc_now())
      |> Repo.delete_all()

    if deleted > 0 do
      Logger.info("Cleaned up #{deleted} expired pending messages")
    end
  end

  defp cache_message(pending) do
    key = {pending.recipient_id, pending.message_id}
    value = %{
      id: pending.id,
      message_id: pending.message_id,
      conversation_id: pending.conversation_id,
      sender_id: pending.sender_id,
      type: pending.message_type,
      content: pending.content,
      metadata: pending.metadata,
      timestamp: pending.inserted_at
    }
    :ets.insert(@table_name, {key, value})
  end

  defp get_cached_messages(user_id, limit) do
    pattern = {{user_id, :_}, :"$1"}
    :ets.match(@table_name, pattern)
    |> List.flatten()
    |> Enum.take(limit)
  end

  defp format_messages(messages) do
    Enum.map(messages, fn m ->
      %{
        id: m.id,
        message_id: m.message_id,
        conversation_id: m.conversation_id,
        sender_id: m.sender_id,
        type: m.message_type,
        content: m.content,
        metadata: m.metadata,
        timestamp: m.inserted_at
      }
    end)
  end

  defp schedule_cleanup do
    # Run cleanup every hour
    Process.send_after(self(), :cleanup_expired, :timer.hours(1))
  end
end
