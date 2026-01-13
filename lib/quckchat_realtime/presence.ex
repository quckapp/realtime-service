defmodule QuckChatRealtime.Presence do
  @moduledoc """
  User presence tracking using Phoenix Presence.

  Tracks:
  - Online/offline status
  - Active device info
  - Last seen timestamp
  - Current conversation focus
  """

  use Phoenix.Presence,
    otp_app: :quckchat_realtime,
    pubsub_server: QuckChatRealtime.PubSub

  alias QuckChatRealtime.Redis

  @doc """
  Track a user's presence when they connect.
  """
  def track_user(socket, user_id, meta \\ %{}) do
    default_meta = %{
      online_at: System.system_time(:second),
      device: Map.get(meta, :device, "unknown"),
      user_agent: Map.get(meta, :user_agent, "unknown")
    }

    # Track in Phoenix Presence
    track(socket, user_id, Map.merge(default_meta, meta))

    # Also store in Redis for cross-node queries
    Redis.set_user_online(user_id, socket.id)
  end

  @doc """
  Untrack a user when they disconnect.
  """
  def untrack_user(socket, user_id) do
    untrack(socket, user_id)
    Redis.set_user_offline(user_id)
  end

  @doc """
  Update a user's presence metadata.
  """
  def update_user(socket, user_id, meta) do
    update(socket, user_id, fn existing ->
      Map.merge(existing, meta)
    end)
  end

  @doc """
  Get list of online users from a topic.
  """
  def get_online_users(topic) do
    list(topic)
    |> Map.keys()
  end

  @doc """
  Check if a specific user is online (works across nodes via Redis).
  """
  def is_online?(user_id) do
    Redis.is_user_online?(user_id)
  end

  @doc """
  Get presence info for a specific user.
  """
  def get_user_presence(user_id) do
    Redis.get_user_presence(user_id)
  end

  @doc """
  Handle presence diff and broadcast to interested parties.
  """
  def handle_diff(diff, topic) do
    # Broadcast joins
    for {user_id, %{metas: metas}} <- diff.joins do
      Phoenix.PubSub.broadcast(
        QuckChatRealtime.PubSub,
        topic,
        {:presence_join, user_id, List.first(metas)}
      )
    end

    # Broadcast leaves
    for {user_id, %{metas: _metas}} <- diff.leaves do
      Phoenix.PubSub.broadcast(
        QuckChatRealtime.PubSub,
        topic,
        {:presence_leave, user_id}
      )
    end
  end
end
