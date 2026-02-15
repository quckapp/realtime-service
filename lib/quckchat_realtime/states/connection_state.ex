defmodule QuckAppRealtime.States.ConnectionState do
  @moduledoc """
  Formal state machine for WebSocket connection lifecycle using Machinery.

  ## States:
  - `:connecting` - Initial connection being established
  - `:authenticating` - Connection established, authenticating user
  - `:connected` - Fully connected and authenticated
  - `:reconnecting` - Connection lost, attempting to reconnect
  - `:disconnecting` - Graceful disconnect in progress
  - `:disconnected` - Connection closed

  ## Transitions:
  ```
  connecting -> authenticating -> connected <-> reconnecting
       |              |              |              |
       v              v              v              v
  disconnected   disconnected   disconnecting  disconnected
                                     |
                                     v
                               disconnected
  ```

  ## Usage:

      # Create a new connection
      conn = ConnectionState.new(socket_id, user_id)

      # Authenticate
      {:ok, conn} = ConnectionState.authenticate(conn, token)

      # Handle disconnect
      {:ok, conn} = ConnectionState.disconnect(conn, :normal)

      # Handle reconnect
      {:ok, conn} = ConnectionState.reconnect(conn)
  """

  use Machinery,
    states: [:connecting, :authenticating, :connected, :reconnecting, :disconnecting, :disconnected],
    transitions: %{
      connecting: [:authenticating, :disconnected],
      authenticating: [:connected, :disconnected],
      connected: [:reconnecting, :disconnecting, :disconnected],
      reconnecting: [:connected, :disconnected],
      disconnecting: [:disconnected],
      disconnected: [:connecting]  # Allow reconnection
    }

  require Logger

  defstruct [
    :socket_id,
    :user_id,
    :state,
    :connected_at,
    :disconnected_at,
    :last_heartbeat,
    :reconnect_count,
    :channels,
    :metadata,
    :device_info,
    :ip_address
  ]

  @type t :: %__MODULE__{
    socket_id: String.t(),
    user_id: String.t() | nil,
    state: atom(),
    connected_at: DateTime.t() | nil,
    disconnected_at: DateTime.t() | nil,
    last_heartbeat: DateTime.t() | nil,
    reconnect_count: integer(),
    channels: [String.t()],
    metadata: map(),
    device_info: map(),
    ip_address: String.t() | nil
  }

  @max_reconnect_attempts 5

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Create a new connection in connecting state.
  """
  def new(socket_id, opts \\ []) do
    %__MODULE__{
      socket_id: socket_id,
      user_id: opts[:user_id],
      state: :connecting,
      connected_at: nil,
      disconnected_at: nil,
      last_heartbeat: nil,
      reconnect_count: 0,
      channels: [],
      metadata: opts[:metadata] || %{},
      device_info: opts[:device_info] || %{},
      ip_address: opts[:ip_address]
    }
  end

  @doc """
  Start authentication process.
  """
  def start_auth(conn) do
    case Machinery.transition_to(conn, :authenticating) do
      {:ok, updated} -> {:ok, updated}
      error -> error
    end
  end

  @doc """
  Complete authentication and transition to connected.
  """
  def authenticate(conn, user_id) do
    updated = %{conn | user_id: user_id}

    case Machinery.transition_to(updated, :connected) do
      {:ok, connected} ->
        {:ok, %{connected |
          connected_at: DateTime.utc_now(),
          last_heartbeat: DateTime.utc_now()
        }}
      error ->
        error
    end
  end

  @doc """
  Fail authentication.
  """
  def auth_failed(conn, reason) do
    case Machinery.transition_to(conn, :disconnected) do
      {:ok, disconnected} ->
        {:ok, %{disconnected |
          disconnected_at: DateTime.utc_now(),
          metadata: Map.put(disconnected.metadata, :disconnect_reason, "auth_failed: #{reason}")
        }}
      error ->
        error
    end
  end

  @doc """
  Handle connection loss - transition to reconnecting.
  """
  def connection_lost(conn) do
    case Machinery.transition_to(conn, :reconnecting) do
      {:ok, reconnecting} ->
        {:ok, %{reconnecting |
          reconnect_count: conn.reconnect_count + 1,
          metadata: Map.put(reconnecting.metadata, :reconnect_started_at, DateTime.utc_now())
        }}
      error ->
        error
    end
  end

  @doc """
  Successful reconnection.
  """
  def reconnect(conn) do
    if conn.reconnect_count >= @max_reconnect_attempts do
      disconnect(conn, :max_reconnects_exceeded)
    else
      case Machinery.transition_to(conn, :connected) do
        {:ok, connected} ->
          {:ok, %{connected | last_heartbeat: DateTime.utc_now()}}
        error ->
          error
      end
    end
  end

  @doc """
  Start graceful disconnect.
  """
  def start_disconnect(conn) do
    case Machinery.transition_to(conn, :disconnecting) do
      {:ok, disconnecting} ->
        {:ok, %{disconnecting |
          metadata: Map.put(disconnecting.metadata, :disconnect_started_at, DateTime.utc_now())
        }}
      error ->
        error
    end
  end

  @doc """
  Complete disconnect.
  """
  def disconnect(conn, reason \\ :normal) do
    case Machinery.transition_to(conn, :disconnected) do
      {:ok, disconnected} ->
        {:ok, %{disconnected |
          disconnected_at: DateTime.utc_now(),
          metadata: Map.put(disconnected.metadata, :disconnect_reason, reason)
        }}
      error ->
        error
    end
  end

  @doc """
  Update heartbeat timestamp.
  """
  def heartbeat(conn) do
    if conn.state == :connected do
      {:ok, %{conn | last_heartbeat: DateTime.utc_now()}}
    else
      {:error, "Can only heartbeat when connected"}
    end
  end

  @doc """
  Join a channel.
  """
  def join_channel(conn, channel) do
    if conn.state == :connected do
      channels = Enum.uniq([channel | conn.channels])
      {:ok, %{conn | channels: channels}}
    else
      {:error, "Must be connected to join channels"}
    end
  end

  @doc """
  Leave a channel.
  """
  def leave_channel(conn, channel) do
    channels = Enum.reject(conn.channels, &(&1 == channel))
    {:ok, %{conn | channels: channels}}
  end

  @doc """
  Get the current state.
  """
  def state(conn), do: conn.state

  @doc """
  Check if connection is active (connected or reconnecting).
  """
  def active?(conn) do
    conn.state in [:connected, :reconnecting]
  end

  @doc """
  Check if connection is in a terminal state.
  """
  def terminal?(conn) do
    conn.state == :disconnected
  end

  @doc """
  Check if heartbeat is stale.
  """
  def stale?(conn, timeout_seconds \\ 60) do
    case conn.last_heartbeat do
      nil -> true
      last ->
        DateTime.diff(DateTime.utc_now(), last, :second) > timeout_seconds
    end
  end

  @doc """
  Get connection duration.
  """
  def duration(conn) do
    case {conn.connected_at, conn.disconnected_at} do
      {nil, _} -> 0
      {connected, nil} -> DateTime.diff(DateTime.utc_now(), connected, :second)
      {connected, disconnected} -> DateTime.diff(disconnected, connected, :second)
    end
  end

  @doc """
  Get connection summary.
  """
  def summary(conn) do
    %{
      socket_id: conn.socket_id,
      user_id: conn.user_id,
      state: conn.state,
      connected_at: conn.connected_at,
      duration_seconds: duration(conn),
      channel_count: length(conn.channels),
      reconnect_count: conn.reconnect_count,
      device_info: conn.device_info
    }
  end

  # ============================================================================
  # Machinery Callbacks
  # ============================================================================

  @doc false
  def guard_transition(conn, :authenticating, :connected) do
    if conn.user_id do
      {:ok, conn}
    else
      {:error, "User ID must be set for authentication"}
    end
  end

  def guard_transition(conn, :reconnecting, :connected) do
    if conn.reconnect_count < @max_reconnect_attempts do
      {:ok, conn}
    else
      {:error, "Max reconnect attempts exceeded"}
    end
  end

  def guard_transition(conn, _from, _to) do
    {:ok, conn}
  end

  @doc false
  def before_transition(conn, _from, to) do
    Logger.debug("[ConnectionState] Socket #{conn.socket_id} transitioning to #{to}")
    conn
  end

  @doc false
  def after_transition(conn, from, to) do
    Logger.info("[ConnectionState] Socket #{conn.socket_id} (user: #{conn.user_id}) transitioned from #{from} to #{to}")

    # Emit telemetry
    :telemetry.execute(
      [:quckapp_realtime, :connection, :state_transition],
      %{count: 1, duration: duration(conn)},
      %{from: from, to: to, user_id: conn.user_id}
    )

    conn
  end
end
