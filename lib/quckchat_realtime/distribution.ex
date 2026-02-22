defmodule QuckAppRealtime.Distribution do
  @moduledoc """
  Consistent hashing for realtime service using ex_hash_ring.

  Provides consistent distribution of:
  - User sessions across nodes
  - WebSocket connections
  - Kafka partition selection
  - Message routing

  ## Usage:

      # Get the Kafka partition for a user
      partition = Distribution.get_partition(user_id)

      # Get the node for handling a user's WebSocket
      node = Distribution.get_node(user_id)

      # Get the Redis pool for a conversation
      pool = Distribution.get_redis_pool(conversation_id)
  """

  use GenServer
  require Logger

  @default_replicas 256
  @default_pool_size 5
  @default_partition_count 3

  # Ring names
  @redis_ring QuckAppRealtime.Distribution.RedisRing
  @partition_ring QuckAppRealtime.Distribution.PartitionRing
  @node_ring QuckAppRealtime.Distribution.NodeRing

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the Kafka partition for a given key.
  Replaces erlang.phash2 for consistent partition selection.
  """
  def get_partition(key, partition_count \\ @default_partition_count) do
    if partition_count != @default_partition_count do
      :erlang.phash2(key, partition_count)
    else
      case ExHashRing.Ring.find_node(@partition_ring, to_string(key)) do
        {:ok, partition} -> partition
        _ -> :erlang.phash2(key, partition_count)
      end
    end
  end

  @doc """
  Get the node that should handle a given user's session.
  """
  def get_node(key) do
    case ExHashRing.Ring.find_node(@node_ring, to_string(key)) do
      {:ok, node_name} -> node_name
      _ -> node()
    end
  end

  @doc """
  Get the Redis pool index for a given key.
  """
  def get_redis_pool(key) do
    case ExHashRing.Ring.find_node(@redis_ring, to_string(key)) do
      {:ok, pool_idx} -> pool_idx
      _ -> :rand.uniform(pool_size()) - 1
    end
  end

  @doc """
  Check if a key should be handled by this node.
  """
  def local?(key) do
    get_node(key) == node()
  end

  @doc """
  Add a node to the ring.
  """
  def add_node(node_name) do
    case ExHashRing.Ring.add_node(@node_ring, node_name) do
      :ok ->
        Logger.info("[Distribution] Added node: #{node_name}")
        :ok
      error ->
        Logger.warning("[Distribution] Failed to add node #{node_name}: #{inspect(error)}")
        error
    end
  end

  @doc """
  Remove a node from the ring.
  """
  def remove_node(node_name) do
    case ExHashRing.Ring.remove_node(@node_ring, node_name) do
      :ok ->
        Logger.info("[Distribution] Removed node: #{node_name}")
        :ok
      error ->
        Logger.warning("[Distribution] Failed to remove node #{node_name}: #{inspect(error)}")
        error
    end
  end

  @doc """
  Get the current ring status.
  """
  def status do
    nodes = case ExHashRing.Ring.get_nodes(@node_ring) do
      {:ok, nodes} -> nodes
      _ -> []
    end

    %{
      nodes: nodes,
      redis_pools: pool_size(),
      partitions: @default_partition_count,
      replicas: @default_replicas,
      local_node: node()
    }
  end

  @doc """
  Get all nodes that should receive a broadcast for a channel.
  Returns list of nodes where channel members are connected.
  """
  def get_broadcast_nodes(_channel_id) do
    # For now, return all nodes. Can be optimized to track which nodes
    # have members of each channel.
    case ExHashRing.Ring.get_nodes(@node_ring) do
      {:ok, nodes} -> nodes
      _ -> [node()]
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Start the hash rings as child processes
    start_rings()

    # Subscribe to node up/down events
    :net_kernel.monitor_nodes(true)

    Logger.info("[Distribution] Initialized with #{@default_replicas} replicas")

    {:ok, %{}}
  end

  @impl true
  def handle_info({:nodeup, node_name}, state) do
    add_node(node_name)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node_name}, state) do
    remove_node(node_name)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp start_rings do
    # Redis pool ring
    pool_nodes = for i <- 0..(pool_size() - 1), do: i
    start_ring(@redis_ring, pool_nodes)

    # Partition ring
    partition_nodes = for i <- 0..(@default_partition_count - 1), do: i
    start_ring(@partition_ring, partition_nodes)

    # Node ring with current cluster nodes
    cluster_nodes = [node() | Node.list()]
    start_ring(@node_ring, cluster_nodes)
  end

  defp start_ring(name, nodes) do
    case ExHashRing.Ring.start_link(
      name: name,
      nodes: nodes,
      replicas: @default_replicas
    ) do
      {:ok, _pid} ->
        Logger.debug("[Distribution] Started ring #{name} with nodes: #{inspect(nodes)}")
        :ok
      {:error, {:already_started, _pid}} ->
        # Ring already exists, update nodes
        ExHashRing.Ring.set_nodes(name, nodes)
        :ok
      error ->
        Logger.error("[Distribution] Failed to start ring #{name}: #{inspect(error)}")
        error
    end
  end

  defp pool_size do
    Application.get_env(:quckapp_realtime, :redis_pool_size, @default_pool_size)
  end
end
