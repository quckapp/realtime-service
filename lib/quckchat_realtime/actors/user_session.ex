defmodule QuckAppRealtime.Actors.UserSession do
  @moduledoc """
  Actor (GenServer) for each connected user - WhatsApp Style.

  Each connected user gets their own Erlang process that:
  - Maintains their WebSocket/TCP connection
  - Handles incoming messages for this user
  - Routes outgoing messages
  - Manages presence state
  - Handles offline message delivery

  This is the core of WhatsApp's architecture - lightweight processes
  that can handle millions of concurrent connections.
  """
  use GenServer, restart: :temporary
  require Logger

  alias QuckAppRealtime.{MessageRouter, PresenceManager, StoreAndForward, NestJSClient}
  alias QuckAppRealtimeWeb.Endpoint

  @heartbeat_interval 30_000        # 30 seconds
  @idle_timeout 300_000             # 5 minutes
  @max_offline_messages 1000

  defstruct [
    :user_id,
    :socket_pid,
    :device_id,
    :device_type,
    :connected_at,
    :last_activity,
    :status,
    :conversations,
    :pending_acks,
    :metadata
  ]

  # ============================================
  # Client API
  # ============================================

  def start_link(opts) do
    user_id = Keyword.fetch!(opts, :user_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(user_id))
  end

  def via_tuple(user_id) do
    {:via, Registry, {QuckAppRealtime.UserRegistry, user_id}}
  end

  @doc "Send a message to this user"
  def send_message(user_id, message) do
    case lookup(user_id) do
      {:ok, pid} -> GenServer.cast(pid, {:send_message, message})
      :not_found -> {:error, :user_offline}
    end
  end

  @doc "Handle incoming message from this user"
  def handle_incoming(user_id, message) do
    case lookup(user_id) do
      {:ok, pid} -> GenServer.cast(pid, {:incoming_message, message})
      :not_found -> {:error, :session_not_found}
    end
  end

  @doc "Update user status"
  def update_status(user_id, status) do
    case lookup(user_id) do
      {:ok, pid} -> GenServer.cast(pid, {:update_status, status})
      :not_found -> {:error, :session_not_found}
    end
  end

  @doc "Get user session state"
  def get_state(user_id) do
    case lookup(user_id) do
      {:ok, pid} -> GenServer.call(pid, :get_state)
      :not_found -> {:error, :session_not_found}
    end
  end

  @doc "Acknowledge message receipt"
  def ack_message(user_id, message_id) do
    case lookup(user_id) do
      {:ok, pid} -> GenServer.cast(pid, {:ack_message, message_id})
      :not_found -> :ok
    end
  end

  @doc "Lookup user process"
  def lookup(user_id) do
    case Registry.lookup(QuckAppRealtime.UserRegistry, user_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :not_found
    end
  end

  @doc "Check if user is online"
  def online?(user_id) do
    case lookup(user_id) do
      {:ok, _pid} -> true
      :not_found -> false
    end
  end

  # ============================================
  # Server Callbacks
  # ============================================

  @impl true
  def init(opts) do
    user_id = Keyword.fetch!(opts, :user_id)
    socket_pid = Keyword.fetch!(opts, :socket_pid)
    device_id = Keyword.get(opts, :device_id, "default")
    device_type = Keyword.get(opts, :device_type, "web")

    # Monitor the socket process
    Process.monitor(socket_pid)

    # Schedule heartbeat
    schedule_heartbeat()

    state = %__MODULE__{
      user_id: user_id,
      socket_pid: socket_pid,
      device_id: device_id,
      device_type: device_type,
      connected_at: DateTime.utc_now(),
      last_activity: DateTime.utc_now(),
      status: "online",
      conversations: MapSet.new(),
      pending_acks: %{},
      metadata: %{}
    }

    Logger.info("User session started: #{user_id} on device #{device_id}")

    # Update presence
    PresenceManager.set_online(user_id, device_id, self())

    # Deliver any pending offline messages
    send(self(), :deliver_pending_messages)

    {:ok, state}
  end

  @impl true
  def handle_cast({:send_message, message}, state) do
    # Send message to user's socket
    send_to_socket(state.socket_pid, {:message, message})

    # Track for acknowledgment
    state = track_pending_ack(state, message)

    {:noreply, update_activity(state)}
  end

  @impl true
  def handle_cast({:incoming_message, message}, state) do
    # User sent a message - route it
    case MessageRouter.route(message, state.user_id) do
      :ok ->
        Logger.debug("Message routed from #{state.user_id}")

      {:queued, recipient_id} ->
        Logger.debug("Message queued for offline user #{recipient_id}")

      {:error, reason} ->
        Logger.error("Failed to route message: #{inspect(reason)}")
        send_to_socket(state.socket_pid, {:error, %{type: "message_failed", reason: reason}})
    end

    {:noreply, update_activity(state)}
  end

  @impl true
  def handle_cast({:update_status, status}, state) do
    PresenceManager.update_status(state.user_id, status)
    {:noreply, %{state | status: status}}
  end

  @impl true
  def handle_cast({:ack_message, message_id}, state) do
    # Message was acknowledged by client
    state = %{state | pending_acks: Map.delete(state.pending_acks, message_id)}
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    # Check if connection is still alive
    if Process.alive?(state.socket_pid) do
      send_to_socket(state.socket_pid, :ping)
      schedule_heartbeat()
      {:noreply, state}
    else
      {:stop, :socket_dead, state}
    end
  end

  @impl true
  def handle_info(:deliver_pending_messages, state) do
    # Fetch and deliver pending offline messages
    case StoreAndForward.get_pending_messages(state.user_id, @max_offline_messages) do
      {:ok, messages} when length(messages) > 0 ->
        Logger.info("Delivering #{length(messages)} pending messages to #{state.user_id}")

        Enum.each(messages, fn msg ->
          send_to_socket(state.socket_pid, {:message, msg})
        end)

        # Messages will be deleted when acknowledged
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{socket_pid: pid} = state) do
    # Socket process died - user disconnected
    Logger.info("User disconnected: #{state.user_id}")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("User session terminated: #{state.user_id}, reason: #{inspect(reason)}")

    # Update presence to offline
    PresenceManager.set_offline(state.user_id, state.device_id)

    # Notify NestJS backend
    Task.start(fn ->
      NestJSClient.update_user_presence(state.user_id, "offline")
    end)

    :ok
  end

  # ============================================
  # Private Functions
  # ============================================

  defp send_to_socket(socket_pid, message) do
    send(socket_pid, {:user_session, message})
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end

  defp update_activity(state) do
    %{state | last_activity: DateTime.utc_now()}
  end

  defp track_pending_ack(state, message) do
    message_id = message[:id] || message["id"]
    if message_id do
      pending = Map.put(state.pending_acks, message_id, DateTime.utc_now())
      %{state | pending_acks: pending}
    else
      state
    end
  end
end
