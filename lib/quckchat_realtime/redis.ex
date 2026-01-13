defmodule QuckChatRealtime.Redis do
  @moduledoc """
  Redis connection manager for distributed state.

  Used for:
  - User presence across nodes
  - Call/Huddle session state
  - Caching
  - Rate limiting
  """

  use Supervisor

  @pool_size 10

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    redis_config = Application.get_env(:quckchat_realtime, :redis, [])

    children =
      for i <- 0..(@pool_size - 1) do
        Supervisor.child_spec(
          {Redix, redis_opts(redis_config, i)},
          id: {Redix, i}
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp redis_opts(config, index) do
    base_opts = [name: :"redix_#{index}"]

    case Keyword.get(config, :url) do
      nil ->
        host = Keyword.get(config, :host, "localhost")
        port = Keyword.get(config, :port, 6379)
        database = Keyword.get(config, :database, 0)
        base_opts ++ [host: host, port: port, database: database]

      url ->
        base_opts ++ [url: url]
    end
  end

  # Public API

  def command(command) do
    Redix.command(random_connection(), command)
  end

  def pipeline(commands) do
    Redix.pipeline(random_connection(), commands)
  end

  defp random_connection do
    :"redix_#{:rand.uniform(@pool_size) - 1}"
  end

  # Presence helpers

  def set_user_online(user_id, socket_id, node_name \\ node()) do
    key = "presence:#{user_id}"
    value = Jason.encode!(%{socket_id: socket_id, node: node_name, connected_at: System.system_time(:second)})
    command(["SET", key, value, "EX", "3600"])
  end

  def set_user_offline(user_id) do
    command(["DEL", "presence:#{user_id}"])
  end

  def get_user_presence(user_id) do
    case command(["GET", "presence:#{user_id}"]) do
      {:ok, nil} -> nil
      {:ok, data} -> Jason.decode!(data)
      _ -> nil
    end
  end

  def is_user_online?(user_id) do
    case command(["EXISTS", "presence:#{user_id}"]) do
      {:ok, 1} -> true
      _ -> false
    end
  end

  # Call session helpers

  def store_call_session(call_id, session_data) do
    key = "call:#{call_id}"
    value = Jason.encode!(session_data)
    command(["SET", key, value, "EX", "7200"])  # 2 hour expiry
  end

  def get_call_session(call_id) do
    case command(["GET", "call:#{call_id}"]) do
      {:ok, nil} -> nil
      {:ok, data} -> Jason.decode!(data)
      _ -> nil
    end
  end

  def delete_call_session(call_id) do
    command(["DEL", "call:#{call_id}"])
  end

  # Huddle session helpers

  def store_huddle_session(huddle_id, session_data) do
    key = "huddle:#{huddle_id}"
    value = Jason.encode!(session_data)
    command(["SET", key, value, "EX", "86400"])  # 24 hour expiry
  end

  def get_huddle_session(huddle_id) do
    case command(["GET", "huddle:#{huddle_id}"]) do
      {:ok, nil} -> nil
      {:ok, data} -> Jason.decode!(data)
      _ -> nil
    end
  end

  def delete_huddle_session(huddle_id) do
    command(["DEL", "huddle:#{huddle_id}"])
  end

  # Rate limiting

  def check_rate_limit(key, max_requests, window_seconds) do
    current_time = System.system_time(:second)
    window_key = "ratelimit:#{key}:#{div(current_time, window_seconds)}"

    case command(["INCR", window_key]) do
      {:ok, count} when count == 1 ->
        command(["EXPIRE", window_key, window_seconds])
        {:ok, count}

      {:ok, count} when count <= max_requests ->
        {:ok, count}

      {:ok, count} ->
        {:error, :rate_limited, count}

      error ->
        error
    end
  end
end
