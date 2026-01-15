defmodule QuckAppRealtime.CallManager do
  @moduledoc """
  GenServer for managing active voice/video calls.

  Responsibilities:
  - Track active calls and their state
  - Route WebRTC signaling messages
  - Handle call lifecycle (initiate, answer, reject, end)
  - Store call history in database
  - Distribute state via Redis for clustering
  """

  use GenServer
  require Logger

  alias QuckAppRealtime.{Redis, Mongo}

  defstruct [
    :call_id,
    :conversation_id,
    :initiator,
    :participants,
    :call_type,
    :status,
    :start_time,
    :db_call_id
  ]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def register_user(user_id, pid) do
    GenServer.call(__MODULE__, {:register_user, user_id, pid})
  end

  def unregister_user(user_id) do
    GenServer.call(__MODULE__, {:unregister_user, user_id})
  end

  def initiate_call(initiator_id, conversation_id, participants, call_type) do
    GenServer.call(__MODULE__, {:initiate_call, initiator_id, conversation_id, participants, call_type})
  end

  def answer_call(call_id, user_id) do
    GenServer.call(__MODULE__, {:answer_call, call_id, user_id})
  end

  def reject_call(call_id, user_id) do
    GenServer.call(__MODULE__, {:reject_call, call_id, user_id})
  end

  def end_call(call_id, reason, ended_by \\ nil) do
    GenServer.call(__MODULE__, {:end_call, call_id, reason, ended_by})
  end

  def get_call(call_id) do
    GenServer.call(__MODULE__, {:get_call, call_id})
  end

  def get_pending_calls(user_id) do
    GenServer.call(__MODULE__, {:get_pending_calls, user_id})
  end

  def send_to_user(user_id, event, payload) do
    GenServer.cast(__MODULE__, {:send_to_user, user_id, event, payload})
  end

  def connected_users_count do
    GenServer.call(__MODULE__, :connected_users_count)
  end

  def active_calls_count do
    GenServer.call(__MODULE__, :active_calls_count)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    state = %{
      users: %{},        # user_id => pid
      calls: %{},        # call_id => %Call{}
      user_calls: %{}    # user_id => [call_ids]
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register_user, user_id, pid}, _from, state) do
    Logger.debug("Registering user #{user_id}")
    Process.monitor(pid)
    users = Map.put(state.users, user_id, pid)
    {:reply, :ok, %{state | users: users}}
  end

  def handle_call({:unregister_user, user_id}, _from, state) do
    Logger.debug("Unregistering user #{user_id}")
    users = Map.delete(state.users, user_id)
    {:reply, :ok, %{state | users: users}}
  end

  def handle_call({:initiate_call, initiator_id, conversation_id, participants, call_type}, _from, state) do
    call_id = generate_call_id()

    call = %__MODULE__{
      call_id: call_id,
      conversation_id: conversation_id,
      initiator: initiator_id,
      participants: [initiator_id | participants],
      call_type: call_type,
      status: "ringing",
      start_time: DateTime.utc_now()
    }

    # Save to database
    db_call = save_call_to_db(call)
    call = %{call | db_call_id: db_call}

    # Store in Redis for cross-node access
    Redis.store_call_session(call_id, call_to_map(call))

    # Update state
    calls = Map.put(state.calls, call_id, call)

    # Track which users are in this call
    user_calls = Enum.reduce(call.participants, state.user_calls, fn user_id, acc ->
      Map.update(acc, user_id, [call_id], &[call_id | &1])
    end)

    # Notify participants
    for participant_id <- participants do
      if pid = Map.get(state.users, participant_id) do
        send(pid, {:incoming_call, %{
          call_id: call_id,
          call_type: call_type,
          conversation_id: conversation_id,
          from: %{id: initiator_id}
        }})
      end
    end

    Logger.info("Call #{call_id} initiated by #{initiator_id}")
    {:reply, {:ok, call}, %{state | calls: calls, user_calls: user_calls}}
  end

  def handle_call({:answer_call, call_id, user_id}, _from, state) do
    case Map.get(state.calls, call_id) do
      nil ->
        # Try to recover from Redis
        case Redis.get_call_session(call_id) do
          nil ->
            {:reply, {:error, :not_found}, state}

          call_data ->
            call = map_to_call(call_data)
            call = %{call | status: "active"}

            calls = Map.put(state.calls, call_id, call)
            Redis.store_call_session(call_id, call_to_map(call))

            update_call_in_db(call.db_call_id, %{status: "active"})

            Logger.info("Call #{call_id} answered by #{user_id}")
            {:reply, {:ok, call}, %{state | calls: calls}}
        end

      call ->
        call = %{call | status: "active"}
        calls = Map.put(state.calls, call_id, call)

        Redis.store_call_session(call_id, call_to_map(call))
        update_call_in_db(call.db_call_id, %{status: "active"})

        Logger.info("Call #{call_id} answered by #{user_id}")
        {:reply, {:ok, call}, %{state | calls: calls}}
    end
  end

  def handle_call({:reject_call, call_id, user_id}, _from, state) do
    case Map.get(state.calls, call_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      call ->
        # Remove call from state
        calls = Map.delete(state.calls, call_id)

        # Clean up user_calls
        user_calls = Enum.reduce(call.participants, state.user_calls, fn uid, acc ->
          Map.update(acc, uid, [], &List.delete(&1, call_id))
        end)

        Redis.delete_call_session(call_id)
        update_call_in_db(call.db_call_id, %{status: "rejected"})

        Logger.info("Call #{call_id} rejected by #{user_id}")
        {:reply, :ok, %{state | calls: calls, user_calls: user_calls}}
    end
  end

  def handle_call({:end_call, call_id, reason, ended_by}, _from, state) do
    case Map.get(state.calls, call_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      call ->
        duration = DateTime.diff(DateTime.utc_now(), call.start_time, :second)

        # Remove call from state
        calls = Map.delete(state.calls, call_id)

        # Clean up user_calls
        user_calls = Enum.reduce(call.participants, state.user_calls, fn uid, acc ->
          Map.update(acc, uid, [], &List.delete(&1, call_id))
        end)

        Redis.delete_call_session(call_id)
        update_call_in_db(call.db_call_id, %{
          status: reason,
          duration: duration,
          ended_by: ended_by
        })

        Logger.info("Call #{call_id} ended (#{reason}) after #{duration}s")
        {:reply, :ok, %{state | calls: calls, user_calls: user_calls}}
    end
  end

  def handle_call({:get_call, call_id}, _from, state) do
    case Map.get(state.calls, call_id) do
      nil ->
        # Try Redis
        case Redis.get_call_session(call_id) do
          nil -> {:reply, {:error, :not_found}, state}
          data -> {:reply, {:ok, map_to_call(data)}, state}
        end

      call ->
        {:reply, {:ok, call}, state}
    end
  end

  def handle_call({:get_pending_calls, user_id}, _from, state) do
    call_ids = Map.get(state.user_calls, user_id, [])

    pending = call_ids
      |> Enum.map(&Map.get(state.calls, &1))
      |> Enum.filter(&(&1 && &1.status == "ringing" && &1.initiator != user_id))

    {:reply, pending, state}
  end

  def handle_call(:connected_users_count, _from, state) do
    {:reply, map_size(state.users), state}
  end

  def handle_call(:active_calls_count, _from, state) do
    {:reply, map_size(state.calls), state}
  end

  @impl true
  def handle_cast({:send_to_user, user_id, event, payload}, state) do
    if pid = Map.get(state.users, user_id) do
      send(pid, {event, payload})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Find and remove the disconnected user
    case Enum.find(state.users, fn {_k, v} -> v == pid end) do
      {user_id, _} ->
        users = Map.delete(state.users, user_id)
        {:noreply, %{state | users: users}}

      nil ->
        {:noreply, state}
    end
  end

  # Private functions

  defp generate_call_id do
    "call_#{System.system_time(:millisecond)}_#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"
  end

  defp call_to_map(call) do
    %{
      "call_id" => call.call_id,
      "conversation_id" => call.conversation_id,
      "initiator" => call.initiator,
      "participants" => call.participants,
      "call_type" => call.call_type,
      "status" => call.status,
      "start_time" => DateTime.to_iso8601(call.start_time),
      "db_call_id" => call.db_call_id
    }
  end

  defp map_to_call(map) do
    %__MODULE__{
      call_id: map["call_id"],
      conversation_id: map["conversation_id"],
      initiator: map["initiator"],
      participants: map["participants"],
      call_type: map["call_type"],
      status: map["status"],
      start_time: DateTime.from_iso8601(map["start_time"]) |> elem(1),
      db_call_id: map["db_call_id"]
    }
  end

  defp save_call_to_db(call) do
    doc = %{
      "conversationId" => BSON.ObjectId.decode!(call.conversation_id),
      "initiatorId" => BSON.ObjectId.decode!(call.initiator),
      "type" => call.call_type,
      "status" => "ringing",
      "participants" => Enum.map(call.participants, fn id ->
        %{
          "userId" => BSON.ObjectId.decode!(id),
          "joinedAt" => nil,
          "leftAt" => nil
        }
      end),
      "startedAt" => call.start_time,
      "endedAt" => nil,
      "duration" => 0,
      "createdAt" => DateTime.utc_now(),
      "updatedAt" => DateTime.utc_now()
    }

    case Mongo.insert_call(doc) do
      {:ok, id} -> BSON.ObjectId.encode!(id)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp update_call_in_db(nil, _updates), do: :ok
  defp update_call_in_db(call_id, updates) do
    Mongo.update_call(call_id, Map.put(updates, "updatedAt", DateTime.utc_now()))
  rescue
    _ -> :ok
  end
end
