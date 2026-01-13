defmodule QuckChatRealtime.ConnectionSupervisor do
  @moduledoc """
  Supervisor for User Session Actors.

  Uses DynamicSupervisor to manage user session processes.
  Each connected user gets their own supervised GenServer.

  WhatsApp-style: Millions of lightweight processes, each handling one user.
  """
  use DynamicSupervisor
  require Logger

  alias QuckChatRealtime.Actors.UserSession

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 1000,
      max_seconds: 60
    )
  end

  @doc """
  Start a new user session when a user connects.
  """
  def start_user_session(user_id, socket_pid, opts \\ []) do
    child_spec = %{
      id: user_id,
      start: {UserSession, :start_link, [[
        user_id: user_id,
        socket_pid: socket_pid,
        device_id: Keyword.get(opts, :device_id, "default"),
        device_type: Keyword.get(opts, :device_type, "web")
      ]]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        Logger.info("Started user session for #{user_id}: #{inspect(pid)}")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.info("User session already exists for #{user_id}: #{inspect(pid)}")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start user session for #{user_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Stop a user session when they disconnect.
  """
  def stop_user_session(user_id) do
    case UserSession.lookup(user_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        :ok

      :not_found ->
        :ok
    end
  end

  @doc """
  Get count of active user sessions.
  """
  def count_sessions do
    DynamicSupervisor.count_children(__MODULE__)
  end

  @doc """
  List all active user sessions.
  """
  def list_sessions do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_, pid, _, _} ->
      case GenServer.call(pid, :get_state, 5000) do
        %{user_id: user_id} = state -> {user_id, state}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
