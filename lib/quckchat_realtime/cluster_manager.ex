defmodule QuckAppRealtime.ClusterManager do
  @moduledoc """
  Erlang Cluster Manager - WhatsApp Style.

  Handles:
  - Node discovery and connection
  - Distributed process registry
  - Cross-node message routing
  - Cluster health monitoring
  - Graceful node addition/removal

  WhatsApp uses Erlang's built-in distribution for their
  millions of concurrent connections across thousands of servers.
  """
  use GenServer
  require Logger

  @heartbeat_interval 5_000
  @node_timeout 15_000

  defmodule State do
    @moduledoc false
    defstruct [
      :node_name,
      :cluster_name,
      :nodes,
      :node_status,
      :last_heartbeat,
      :discovery_strategy
    ]
  end

  # ============================================
  # Client API
  # ============================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get all connected nodes"
  def get_nodes do
    GenServer.call(__MODULE__, :get_nodes)
  end

  @doc "Get cluster status"
  def cluster_status do
    GenServer.call(__MODULE__, :cluster_status)
  end

  @doc "Manually connect to a node"
  def connect_node(node_name) do
    GenServer.call(__MODULE__, {:connect, node_name})
  end

  @doc "Disconnect from a node"
  def disconnect_node(node_name) do
    GenServer.call(__MODULE__, {:disconnect, node_name})
  end

  @doc "Find which node a user is connected to"
  def find_user_node(user_id) do
    # Check local registry first
    case Registry.lookup(QuckAppRealtime.UserRegistry, user_id) do
      [{_pid, _}] ->
        {:ok, node()}

      [] ->
        # Ask other nodes
        find_user_on_remote_nodes(user_id)
    end
  end

  @doc "Route message to user regardless of which node they're on"
  def route_to_user(user_id, message) do
    case find_user_node(user_id) do
      {:ok, target_node} when target_node == node() ->
        # User is on this node
        QuckAppRealtime.Actors.UserSession.send_message(user_id, message)

      {:ok, target_node} ->
        # User is on remote node
        :rpc.cast(target_node, QuckAppRealtime.Actors.UserSession, :send_message, [user_id, message])
        :ok

      {:error, :not_found} ->
        {:error, :user_not_connected}
    end
  end

  # ============================================
  # Server Callbacks
  # ============================================

  @impl true
  def init(opts) do
    # Set up node monitoring
    :net_kernel.monitor_nodes(true)

    cluster_name = Keyword.get(opts, :cluster_name, :quckapp_cluster)
    discovery = Keyword.get(opts, :discovery, :static)

    state = %State{
      node_name: node(),
      cluster_name: cluster_name,
      nodes: MapSet.new(),
      node_status: %{},
      last_heartbeat: %{},
      discovery_strategy: discovery
    }

    # Start discovery based on strategy
    send(self(), :discover_nodes)

    # Schedule heartbeat
    schedule_heartbeat()

    Logger.info("Cluster Manager started on node #{node()}")

    {:ok, state}
  end

  @impl true
  def handle_call(:get_nodes, _from, state) do
    nodes = [node() | Node.list()]
    {:reply, nodes, state}
  end

  @impl true
  def handle_call(:cluster_status, _from, state) do
    status = %{
      node: node(),
      cluster_name: state.cluster_name,
      connected_nodes: Node.list(),
      total_nodes: length(Node.list()) + 1,
      node_status: state.node_status,
      discovery_strategy: state.discovery_strategy
    }
    {:reply, status, state}
  end

  @impl true
  def handle_call({:connect, node_name}, _from, state) do
    result = Node.connect(node_name)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:disconnect, node_name}, _from, state) do
    result = Node.disconnect(node_name)
    {:reply, result, state}
  end

  @impl true
  def handle_info({:nodeup, node_name}, state) do
    Logger.info("Node connected: #{node_name}")

    # Sync global state with new node
    sync_with_node(node_name)

    state = %{state |
      nodes: MapSet.put(state.nodes, node_name),
      node_status: Map.put(state.node_status, node_name, :connected),
      last_heartbeat: Map.put(state.last_heartbeat, node_name, System.system_time(:millisecond))
    }

    # Broadcast presence data to new node
    broadcast_local_presence(node_name)

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node_name}, state) do
    Logger.warning("Node disconnected: #{node_name}")

    state = %{state |
      nodes: MapSet.delete(state.nodes, node_name),
      node_status: Map.put(state.node_status, node_name, :disconnected)
    }

    # Handle users that were on the disconnected node
    handle_node_failure(node_name)

    {:noreply, state}
  end

  @impl true
  def handle_info(:discover_nodes, state) do
    case state.discovery_strategy do
      :static ->
        discover_static_nodes()

      :dns ->
        discover_dns_nodes(state.cluster_name)

      :kubernetes ->
        discover_k8s_nodes()

      _ ->
        :ok
    end

    # Re-schedule discovery
    Process.send_after(self(), :discover_nodes, 30_000)

    {:noreply, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    # Send heartbeat to all nodes
    Enum.each(Node.list(), fn node_name ->
      :rpc.cast(node_name, __MODULE__, :receive_heartbeat, [node()])
    end)

    # Check for timed out nodes
    state = check_node_timeouts(state)

    schedule_heartbeat()
    {:noreply, state}
  end

  @impl true
  def handle_info({:heartbeat_from, from_node}, state) do
    state = %{state |
      last_heartbeat: Map.put(state.last_heartbeat, from_node, System.system_time(:millisecond))
    }
    {:noreply, state}
  end

  # ============================================
  # Public RPC Functions (called by other nodes)
  # ============================================

  @doc "Receive heartbeat from another node"
  def receive_heartbeat(from_node) do
    GenServer.cast(__MODULE__, {:heartbeat_from, from_node})
  end

  @doc "Check if a user is connected to this node"
  def user_on_this_node?(user_id) do
    case Registry.lookup(QuckAppRealtime.UserRegistry, user_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  @doc "Get users connected to this node"
  def get_local_users do
    Registry.select(QuckAppRealtime.UserRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  # ============================================
  # Private Functions
  # ============================================

  defp find_user_on_remote_nodes(user_id) do
    nodes = Node.list()

    result = Enum.find_value(nodes, fn node_name ->
      case :rpc.call(node_name, __MODULE__, :user_on_this_node?, [user_id], 5_000) do
        true -> {:ok, node_name}
        _ -> nil
      end
    end)

    result || {:error, :not_found}
  end

  defp discover_static_nodes do
    # Read from config
    nodes = Application.get_env(:quckapp_realtime, :cluster_nodes, [])

    Enum.each(nodes, fn node_name ->
      unless node_name == node() do
        Node.connect(node_name)
      end
    end)
  end

  defp discover_dns_nodes(cluster_name) do
    # DNS-based discovery (useful for Kubernetes headless services)
    dns_name = Application.get_env(:quckapp_realtime, :cluster_dns, "quckapp-realtime.default.svc.cluster.local")

    case :inet_res.lookup(to_charlist(dns_name), :in, :a) do
      [] ->
        Logger.debug("No nodes found via DNS")

      ips ->
        Enum.each(ips, fn ip ->
          node_name = :"#{cluster_name}@#{:inet.ntoa(ip)}"
          unless node_name == node() do
            Node.connect(node_name)
          end
        end)
    end
  end

  defp discover_k8s_nodes do
    # Kubernetes API-based discovery
    # Requires K8S_NAMESPACE and K8S_SERVICE_NAME env vars
    namespace = System.get_env("K8S_NAMESPACE", "default")
    service = System.get_env("K8S_SERVICE_NAME", "quckapp-realtime")

    # This would call K8S API to get endpoints
    # For now, fall back to DNS discovery
    discover_dns_nodes(:quckapp_cluster)
  end

  defp sync_with_node(node_name) do
    # Sync global state tables with new node
    Task.start(fn ->
      # Sync presence data
      local_presence = QuckAppRealtime.PresenceManager.get_online_users()
      :rpc.cast(node_name, __MODULE__, :receive_presence_sync, [node(), local_presence])
    end)
  end

  @doc "Receive presence sync from another node"
  def receive_presence_sync(from_node, users) do
    Logger.debug("Received presence sync from #{from_node}: #{length(users)} users")
    # Store remote presence info
    # This would be used for cross-node presence queries
  end

  defp broadcast_local_presence(target_node) do
    local_users = get_local_users()
    :rpc.cast(target_node, __MODULE__, :receive_presence_sync, [node(), local_users])
  end

  defp handle_node_failure(_node_name) do
    # When a node goes down, users connected to it are now offline
    # The presence will be updated when they reconnect to another node
    # Push notifications for offline users will handle message delivery
    :ok
  end

  defp check_node_timeouts(state) do
    now = System.system_time(:millisecond)

    timed_out = state.last_heartbeat
      |> Enum.filter(fn {_node, last_seen} ->
        now - last_seen > @node_timeout
      end)
      |> Enum.map(fn {node_name, _} -> node_name end)

    Enum.each(timed_out, fn node_name ->
      Logger.warning("Node #{node_name} timed out - no heartbeat received")
      Node.disconnect(node_name)
    end)

    %{state |
      node_status: Enum.reduce(timed_out, state.node_status, fn node_name, acc ->
        Map.put(acc, node_name, :timed_out)
      end)
    }
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end
end
