defmodule QuckAppRealtime.SignalingServer do
  @moduledoc """
  WebRTC Signaling Server for call establishment.

  Handles:
  - SDP offer/answer exchange
  - ICE candidate exchange
  - TURN credential generation
  - Signal queueing for offline delivery
  - Cross-node signal routing via Redis
  """
  use GenServer
  require Logger

  alias QuckAppRealtime.Redis
  alias Phoenix.PubSub

  @signal_ttl 60  # 60 seconds TTL for pending signals

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  # ============================================
  # Public API - SDP Exchange
  # ============================================

  @doc "Send SDP offer to target user"
  def send_offer(call_id, from_user_id, to_user_id, sdp) do
    signal = %{
      type: "offer",
      call_id: call_id,
      from: from_user_id,
      sdp: sdp,
      timestamp: System.system_time(:millisecond)
    }

    deliver_signal(call_id, to_user_id, signal)
  end

  @doc "Send SDP answer to target user"
  def send_answer(call_id, from_user_id, to_user_id, sdp) do
    signal = %{
      type: "answer",
      call_id: call_id,
      from: from_user_id,
      sdp: sdp,
      timestamp: System.system_time(:millisecond)
    }

    deliver_signal(call_id, to_user_id, signal)
  end

  @doc "Send ICE candidate to target user"
  def send_ice_candidate(call_id, from_user_id, to_user_id, candidate) do
    signal = %{
      type: "ice-candidate",
      call_id: call_id,
      from: from_user_id,
      candidate: candidate,
      timestamp: System.system_time(:millisecond)
    }

    deliver_signal(call_id, to_user_id, signal)
  end

  @doc "Get pending signals for a user in a call"
  def get_pending_signals(call_id, user_id) do
    key = signal_queue_key(call_id, user_id)

    case Redis.command(["LRANGE", key, "0", "-1"]) do
      {:ok, signals} when is_list(signals) ->
        # Clear the queue after reading
        Redis.command(["DEL", key])

        Enum.map(signals, fn signal ->
          Jason.decode!(signal)
        end)

      _ ->
        []
    end
  end

  # ============================================
  # Public API - ICE Servers
  # ============================================

  @doc "Get ICE server configuration"
  def get_ice_servers do
    webrtc_config = Application.get_env(:quckapp_realtime, :webrtc, [])

    stun_servers = Keyword.get(webrtc_config, :stun_servers, [
      "stun:stun.l.google.com:19302",
      "stun:stun1.l.google.com:19302"
    ])

    turn_server = Keyword.get(webrtc_config, :turn_server)
    turn_username = Keyword.get(webrtc_config, :turn_username)
    turn_credential = Keyword.get(webrtc_config, :turn_credential)

    servers = Enum.map(stun_servers, fn url ->
      %{urls: url}
    end)

    if turn_server && turn_username && turn_credential do
      turn = %{
        urls: turn_server,
        username: turn_username,
        credential: turn_credential
      }
      servers ++ [turn]
    else
      servers
    end
  end

  @doc """
  Generate time-limited TURN credentials for a user.

  Uses HMAC-SHA1 for credential generation as per RFC 5766.
  """
  def generate_turn_credentials(user_id) do
    webrtc_config = Application.get_env(:quckapp_realtime, :webrtc, [])
    turn_server = Keyword.get(webrtc_config, :turn_server)
    turn_secret = Keyword.get(webrtc_config, :turn_secret)

    if turn_server && turn_secret do
      # TTL of 24 hours
      ttl = 86400
      timestamp = System.system_time(:second) + ttl

      # Username format: timestamp:user_id
      username = "#{timestamp}:#{user_id}"

      # Generate HMAC-SHA1 credential
      credential = :crypto.mac(:hmac, :sha, turn_secret, username)
                   |> Base.encode64()

      %{
        username: username,
        credential: credential,
        ttl: ttl,
        urls: parse_turn_urls(turn_server)
      }
    else
      # Return static credentials if no secret configured
      static_credential = Keyword.get(webrtc_config, :turn_credential)

      %{
        username: Keyword.get(webrtc_config, :turn_username, user_id),
        credential: static_credential,
        ttl: 86400,
        urls: if(turn_server, do: parse_turn_urls(turn_server), else: [])
      }
    end
  end

  @doc "Get full ICE configuration including TURN credentials for a user"
  def get_ice_config(user_id) do
    webrtc_config = Application.get_env(:quckapp_realtime, :webrtc, [])

    stun_servers = Keyword.get(webrtc_config, :stun_servers, [
      "stun:stun.l.google.com:19302"
    ])

    stun_configs = Enum.map(stun_servers, fn url ->
      %{urls: url}
    end)

    turn_config = case generate_turn_credentials(user_id) do
      %{urls: urls, username: username, credential: credential} when urls != [] ->
        [%{
          urls: urls,
          username: username,
          credential: credential
        }]

      _ ->
        []
    end

    %{
      iceServers: stun_configs ++ turn_config,
      iceCandidatePoolSize: 10,
      iceTransportPolicy: "all"
    }
  end

  # ============================================
  # Private Functions
  # ============================================

  defp deliver_signal(call_id, to_user_id, signal) do
    # Try to deliver via PubSub first (user might be connected)
    PubSub.broadcast(
      QuckAppRealtime.PubSub,
      "signal:#{call_id}:#{to_user_id}",
      {:signal, signal}
    )

    # Also queue in Redis for reliability
    queue_signal(call_id, to_user_id, signal)

    :ok
  end

  defp queue_signal(call_id, user_id, signal) do
    key = signal_queue_key(call_id, user_id)
    value = Jason.encode!(signal)

    Redis.pipeline([
      ["RPUSH", key, value],
      ["EXPIRE", key, @signal_ttl]
    ])
  end

  defp signal_queue_key(call_id, user_id) do
    "signal:queue:#{call_id}:#{user_id}"
  end

  defp parse_turn_urls(turn_server) when is_binary(turn_server) do
    # Support both single URL and comma-separated list
    turn_server
    |> String.split(",")
    |> Enum.map(&String.trim/1)
  end

  defp parse_turn_urls(turn_servers) when is_list(turn_servers) do
    turn_servers
  end

  defp parse_turn_urls(_), do: []
end
