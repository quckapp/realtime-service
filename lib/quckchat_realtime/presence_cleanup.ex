defmodule QuckChatRealtime.PresenceCleanup do
  @moduledoc """
  Periodic cleanup of stale presence records.

  Handles:
  - Cleaning up users who disconnected without proper cleanup
  - Removing expired heartbeats from Redis
  - Syncing ETS presence with Redis state
  - Publishing presence cleanup events to Kafka
  """
  use GenServer
  require Logger

  alias QuckChatRealtime.{Redis, PresenceManager, Kafka}

  @cleanup_interval 30_000  # 30 seconds
  @stale_threshold 120  # 2 minutes without heartbeat
  @batch_size 100

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_cleanup()
    schedule_redis_sync()

    {:ok, %{
      last_cleanup: nil,
      cleaned_count: 0
    }}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleaned = cleanup_stale_presence()
    schedule_cleanup()

    {:noreply, %{state |
      last_cleanup: DateTime.utc_now(),
      cleaned_count: state.cleaned_count + cleaned
    }}
  end

  @impl true
  def handle_info(:sync_redis, state) do
    sync_ets_with_redis()
    schedule_redis_sync()
    {:noreply, state}
  end

  # ============================================
  # Cleanup Functions
  # ============================================

  defp cleanup_stale_presence do
    threshold = DateTime.add(DateTime.utc_now(), -@stale_threshold, :second)

    # Get all presence records from ETS
    stale_users = PresenceManager.get_online_users()
    |> Enum.filter(fn user_id ->
      case PresenceManager.get_presence(user_id) do
        {:ok, %{last_seen: last_seen}} when not is_nil(last_seen) ->
          DateTime.compare(last_seen, threshold) == :lt

        _ ->
          false
      end
    end)
    |> Enum.take(@batch_size)

    # Mark stale users as offline
    Enum.each(stale_users, fn user_id ->
      Logger.info("Cleaning up stale presence for user #{user_id}")

      # Update presence to offline
      PresenceManager.set_offline(user_id)

      # Clean up Redis
      Redis.set_user_offline(user_id)

      # Publish cleanup event
      publish_presence_cleanup_event(user_id)
    end)

    count = length(stale_users)

    if count > 0 do
      Logger.info("Cleaned up #{count} stale presence records")
      :telemetry.execute([:presence, :cleanup], %{count: count}, %{})
    end

    count
  end

  defp sync_ets_with_redis do
    # Scan Redis for presence keys and sync with ETS
    case Redis.command(["KEYS", "presence:*"]) do
      {:ok, keys} when is_list(keys) ->
        redis_user_ids = Enum.map(keys, fn key ->
          String.replace_prefix(key, "presence:", "")
        end)

        ets_user_ids = PresenceManager.get_online_users()

        # Find users in ETS but not in Redis (stale)
        stale_in_ets = ets_user_ids -- redis_user_ids

        Enum.each(stale_in_ets, fn user_id ->
          Logger.debug("Syncing stale ETS presence for #{user_id}")
          PresenceManager.set_offline(user_id)
        end)

        # Find users in Redis but not in ETS (missed connection)
        missing_in_ets = redis_user_ids -- ets_user_ids

        Enum.each(missing_in_ets, fn user_id ->
          case Redis.get_user_presence(user_id) do
            %{"node" => node_name} when node_name == to_string(node()) ->
              # This node should have this user - clean up Redis
              Logger.debug("Cleaning orphaned Redis presence for #{user_id}")
              Redis.set_user_offline(user_id)

            _ ->
              # User is on another node, ignore
              :ok
          end
        end)

      _ ->
        :ok
    end
  end

  defp publish_presence_cleanup_event(user_id) do
    event = %{
      type: "presence.cleanup",
      user_id: user_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      node: to_string(node())
    }

    Kafka.Producer.publish("presence-events", user_id, event)
  rescue
    _ -> :ok
  end

  # ============================================
  # Scheduling
  # ============================================

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp schedule_redis_sync do
    # Sync every minute
    Process.send_after(self(), :sync_redis, 60_000)
  end
end
