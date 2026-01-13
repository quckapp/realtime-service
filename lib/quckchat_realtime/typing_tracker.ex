defmodule QuckChatRealtime.TypingTracker do
  @moduledoc """
  Enhanced Typing Indicator Tracker using MapSet.

  Tracks typing indicators across conversations with:
  - Efficient MapSet-based storage
  - Automatic timeout cleanup
  - Telemetry metrics
  - PubSub broadcast
  - Cross-node sync via Redis
  """
  use GenServer
  require Logger

  alias QuckChatRealtime.Redis
  alias Phoenix.PubSub

  @typing_timeout 5_000  # 5 seconds
  @cleanup_interval 10_000  # 10 seconds
  @redis_ttl 10  # 10 seconds Redis TTL

  defstruct typing: %{}, timers: %{}

  # ============================================
  # Client API
  # ============================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Mark user as typing in a conversation"
  def start_typing(conversation_id, user_id) do
    GenServer.cast(__MODULE__, {:start_typing, conversation_id, user_id})
  end

  @doc "Mark user as stopped typing"
  def stop_typing(conversation_id, user_id) do
    GenServer.cast(__MODULE__, {:stop_typing, conversation_id, user_id})
  end

  @doc "Get all users currently typing in a conversation"
  def get_typing_users(conversation_id) do
    GenServer.call(__MODULE__, {:get_typing, conversation_id})
  end

  @doc "Check if a specific user is typing in a conversation"
  def is_typing?(conversation_id, user_id) do
    GenServer.call(__MODULE__, {:is_typing, conversation_id, user_id})
  end

  @doc "Get typing counts per conversation (for metrics)"
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # ============================================
  # Server Callbacks
  # ============================================

  @impl true
  def init(_opts) do
    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, %__MODULE__{
      typing: %{},
      timers: %{}
    }}
  end

  @impl true
  def handle_cast({:start_typing, conversation_id, user_id}, state) do
    key = {conversation_id, user_id}

    # Cancel existing timer if any
    state = cancel_timer(state, key)

    # Set new timeout timer
    timer_ref = Process.send_after(self(), {:typing_timeout, key}, @typing_timeout)

    # Update typing users for this conversation
    typing = Map.update(
      state.typing,
      conversation_id,
      MapSet.new([user_id]),
      &MapSet.put(&1, user_id)
    )

    # Update timers
    timers = Map.put(state.timers, key, timer_ref)

    # Broadcast typing indicator
    broadcast_typing(conversation_id, user_id, true)

    # Sync to Redis for cross-node awareness
    sync_to_redis(conversation_id, user_id, true)

    # Telemetry
    :telemetry.execute([:typing, :started], %{count: 1}, %{
      conversation_id: conversation_id,
      user_id: user_id
    })

    {:noreply, %{state | typing: typing, timers: timers}}
  end

  @impl true
  def handle_cast({:stop_typing, conversation_id, user_id}, state) do
    key = {conversation_id, user_id}

    # Cancel timer
    state = cancel_timer(state, key)

    # Remove user from typing set
    typing = Map.update(
      state.typing,
      conversation_id,
      MapSet.new(),
      &MapSet.delete(&1, user_id)
    )

    # Clean up empty sets
    typing = if MapSet.size(Map.get(typing, conversation_id, MapSet.new())) == 0 do
      Map.delete(typing, conversation_id)
    else
      typing
    end

    # Broadcast stop typing
    broadcast_typing(conversation_id, user_id, false)

    # Sync to Redis
    sync_to_redis(conversation_id, user_id, false)

    # Telemetry
    :telemetry.execute([:typing, :stopped], %{count: 1}, %{
      conversation_id: conversation_id,
      user_id: user_id
    })

    {:noreply, %{state | typing: typing}}
  end

  @impl true
  def handle_call({:get_typing, conversation_id}, _from, state) do
    users = state.typing
    |> Map.get(conversation_id, MapSet.new())
    |> MapSet.to_list()

    {:reply, {:ok, users}, state}
  end

  @impl true
  def handle_call({:is_typing, conversation_id, user_id}, _from, state) do
    is_typing = state.typing
    |> Map.get(conversation_id, MapSet.new())
    |> MapSet.member?(user_id)

    {:reply, is_typing, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      active_conversations: map_size(state.typing),
      total_typing_users: Enum.reduce(state.typing, 0, fn {_, users}, acc ->
        acc + MapSet.size(users)
      end),
      per_conversation: Enum.map(state.typing, fn {conv_id, users} ->
        {conv_id, MapSet.size(users)}
      end)
      |> Map.new()
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info({:typing_timeout, {conversation_id, user_id} = key}, state) do
    Logger.debug("Typing timeout for #{user_id} in #{conversation_id}")

    # Remove from typing set
    typing = Map.update(
      state.typing,
      conversation_id,
      MapSet.new(),
      &MapSet.delete(&1, user_id)
    )

    # Clean up empty sets
    typing = if MapSet.size(Map.get(typing, conversation_id, MapSet.new())) == 0 do
      Map.delete(typing, conversation_id)
    else
      typing
    end

    # Remove timer reference
    timers = Map.delete(state.timers, key)

    # Broadcast stop typing
    broadcast_typing(conversation_id, user_id, false)

    # Sync to Redis
    sync_to_redis(conversation_id, user_id, false)

    {:noreply, %{state | typing: typing, timers: timers}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Cleanup any stale entries (defensive)
    # In practice, timeouts should handle this

    # Report metrics
    total = Enum.reduce(state.typing, 0, fn {_, users}, acc ->
      acc + MapSet.size(users)
    end)

    :telemetry.execute([:typing, :active], %{
      conversations: map_size(state.typing),
      users: total
    }, %{})

    schedule_cleanup()
    {:noreply, state}
  end

  # ============================================
  # Private Functions
  # ============================================

  defp cancel_timer(state, key) do
    case Map.get(state.timers, key) do
      nil -> state
      timer_ref ->
        Process.cancel_timer(timer_ref)
        %{state | timers: Map.delete(state.timers, key)}
    end
  end

  defp broadcast_typing(conversation_id, user_id, is_typing) do
    PubSub.broadcast(
      QuckChatRealtime.PubSub,
      "conversation:#{conversation_id}",
      {:typing, user_id, is_typing}
    )
  end

  defp sync_to_redis(conversation_id, user_id, true) do
    key = "typing:#{conversation_id}:#{user_id}"
    Redis.command(["SET", key, "1", "EX", @redis_ttl])
  rescue
    _ -> :ok
  end

  defp sync_to_redis(conversation_id, user_id, false) do
    key = "typing:#{conversation_id}:#{user_id}"
    Redis.command(["DEL", key])
  rescue
    _ -> :ok
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
