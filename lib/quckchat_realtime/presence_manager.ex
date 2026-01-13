defmodule QuckChatRealtime.PresenceManager do
  @moduledoc """
  WhatsApp-Style Presence Manager using ETS.

  Tracks:
  - Online/Offline status
  - Last seen timestamps
  - Active devices per user
  - Typing indicators

  Uses ETS for O(1) lookups - critical for presence checks
  during message routing.

  For distributed systems, this syncs with Redis for cross-node awareness.
  """
  use GenServer
  require Logger

  alias QuckChatRealtime.Redis

  @presence_table :user_presence
  @typing_table :typing_indicators
  @devices_table :user_devices

  @typing_timeout 10_000  # 10 seconds
  @presence_sync_interval 30_000  # 30 seconds

  # ============================================
  # Client API
  # ============================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Set user as online"
  def set_online(user_id, device_id \\ "default", pid \\ nil) do
    GenServer.cast(__MODULE__, {:set_online, user_id, device_id, pid})
  end

  @doc "Set user as offline"
  def set_offline(user_id, device_id \\ "default") do
    GenServer.cast(__MODULE__, {:set_offline, user_id, device_id})
  end

  @doc "Update user status (online, away, busy)"
  def update_status(user_id, status) do
    GenServer.cast(__MODULE__, {:update_status, user_id, status})
  end

  @doc "Check if user is online (any device)"
  def is_online?(user_id) do
    case :ets.lookup(@presence_table, user_id) do
      [{^user_id, %{status: status}}] when status != "offline" -> true
      _ -> false
    end
  end

  @doc "Get user presence info"
  def get_presence(user_id) do
    case :ets.lookup(@presence_table, user_id) do
      [{^user_id, presence}] -> {:ok, presence}
      [] -> {:ok, %{status: "offline", last_seen: nil}}
    end
  end

  @doc "Get presence for multiple users"
  def get_presence_bulk(user_ids) do
    Enum.reduce(user_ids, %{}, fn user_id, acc ->
      {:ok, presence} = get_presence(user_id)
      Map.put(acc, user_id, presence)
    end)
  end

  @doc "Get all online users"
  def get_online_users do
    :ets.foldl(fn
      {user_id, %{status: status}}, acc when status != "offline" ->
        [user_id | acc]
      _, acc ->
        acc
    end, [], @presence_table)
  end

  @doc "Set typing indicator"
  def set_typing(user_id, conversation_id, is_typing) do
    GenServer.cast(__MODULE__, {:set_typing, user_id, conversation_id, is_typing})
  end

  @doc "Get users typing in a conversation"
  def get_typing_users(conversation_id) do
    now = System.system_time(:millisecond)

    :ets.foldl(fn
      {{^conversation_id, user_id}, timestamp}, acc when now - timestamp < @typing_timeout ->
        [user_id | acc]
      _, acc ->
        acc
    end, [], @typing_table)
  end

  @doc "Get user's active devices"
  def get_user_devices(user_id) do
    case :ets.lookup(@devices_table, user_id) do
      [{^user_id, devices}] -> devices
      [] -> []
    end
  end

  # ============================================
  # Server Callbacks
  # ============================================

  @impl true
  def init(_opts) do
    # Create ETS tables
    :ets.new(@presence_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@typing_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@devices_table, [:named_table, :set, :public, read_concurrency: true])

    # Schedule periodic sync with Redis
    schedule_sync()

    # Schedule typing cleanup
    schedule_typing_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:set_online, user_id, device_id, pid}, state) do
    now = DateTime.utc_now()

    # Update presence
    presence = %{
      status: "online",
      last_seen: now,
      updated_at: now
    }
    :ets.insert(@presence_table, {user_id, presence})

    # Track device
    add_device(user_id, device_id, pid)

    # Sync to Redis for cross-node awareness
    sync_presence_to_redis(user_id, presence)

    # Broadcast presence change
    broadcast_presence_change(user_id, "online")

    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_offline, user_id, device_id}, state) do
    # Remove device
    remove_device(user_id, device_id)

    # Check if user has other devices
    remaining_devices = get_user_devices(user_id)

    if length(remaining_devices) == 0 do
      # No more devices - user is offline
      now = DateTime.utc_now()
      presence = %{
        status: "offline",
        last_seen: now,
        updated_at: now
      }
      :ets.insert(@presence_table, {user_id, presence})

      # Sync to Redis
      sync_presence_to_redis(user_id, presence)

      # Broadcast
      broadcast_presence_change(user_id, "offline")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:update_status, user_id, status}, state) do
    case :ets.lookup(@presence_table, user_id) do
      [{^user_id, presence}] ->
        updated = %{presence | status: status, updated_at: DateTime.utc_now()}
        :ets.insert(@presence_table, {user_id, updated})
        sync_presence_to_redis(user_id, updated)
        broadcast_presence_change(user_id, status)

      [] ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_typing, user_id, conversation_id, true}, state) do
    :ets.insert(@typing_table, {{conversation_id, user_id}, System.system_time(:millisecond)})
    broadcast_typing(conversation_id, user_id, true)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_typing, user_id, conversation_id, false}, state) do
    :ets.delete(@typing_table, {conversation_id, user_id})
    broadcast_typing(conversation_id, user_id, false)
    {:noreply, state}
  end

  @impl true
  def handle_info(:sync_presence, state) do
    # Sync local presence to Redis periodically
    :ets.foldl(fn {user_id, presence}, _ ->
      sync_presence_to_redis(user_id, presence)
    end, nil, @presence_table)

    schedule_sync()
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup_typing, state) do
    now = System.system_time(:millisecond)

    # Remove stale typing indicators
    :ets.foldl(fn
      {{conv_id, user_id}, timestamp}, _ when now - timestamp >= @typing_timeout ->
        :ets.delete(@typing_table, {conv_id, user_id})
      _, _ ->
        :ok
    end, nil, @typing_table)

    schedule_typing_cleanup()
    {:noreply, state}
  end

  # ============================================
  # Private Functions
  # ============================================

  defp add_device(user_id, device_id, pid) do
    devices = get_user_devices(user_id)
    device = %{id: device_id, pid: pid, connected_at: DateTime.utc_now()}
    updated = [device | Enum.reject(devices, &(&1.id == device_id))]
    :ets.insert(@devices_table, {user_id, updated})
  end

  defp remove_device(user_id, device_id) do
    devices = get_user_devices(user_id)
    updated = Enum.reject(devices, &(&1.id == device_id))
    :ets.insert(@devices_table, {user_id, updated})
  end

  defp sync_presence_to_redis(user_id, presence) do
    Task.start(fn ->
      Redis.set_presence(user_id, presence)
    end)
  end

  defp broadcast_presence_change(user_id, status) do
    Phoenix.PubSub.broadcast(
      QuckChatRealtime.PubSub,
      "presence:updates",
      {:presence_changed, user_id, status}
    )
  end

  defp broadcast_typing(conversation_id, user_id, is_typing) do
    Phoenix.PubSub.broadcast(
      QuckChatRealtime.PubSub,
      "conversation:#{conversation_id}",
      {:typing, user_id, is_typing}
    )
  end

  defp schedule_sync do
    Process.send_after(self(), :sync_presence, @presence_sync_interval)
  end

  defp schedule_typing_cleanup do
    Process.send_after(self(), :cleanup_typing, @typing_timeout)
  end
end
