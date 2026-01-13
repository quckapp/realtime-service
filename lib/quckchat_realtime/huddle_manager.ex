defmodule QuckChatRealtime.HuddleManager do
  @moduledoc """
  GenServer for managing Huddles (persistent group audio/video rooms).

  Unlike calls, Huddles:
  - Are persistent (tied to a conversation)
  - Allow join/leave freely
  - Support multiple participants
  - Include screen sharing
  """

  use GenServer
  require Logger

  alias QuckChatRealtime.Redis

  defstruct [
    :huddle_id,
    :conversation_id,
    :name,
    :creator,
    :participants,
    :screen_sharer,
    :created_at,
    :settings
  ]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def create_huddle(creator_id, conversation_id, name) do
    GenServer.call(__MODULE__, {:create_huddle, creator_id, conversation_id, name})
  end

  def join_huddle(huddle_id, user_id, opts \\ %{}) do
    GenServer.call(__MODULE__, {:join_huddle, huddle_id, user_id, opts})
  end

  def leave_huddle(huddle_id, user_id) do
    GenServer.call(__MODULE__, {:leave_huddle, huddle_id, user_id})
  end

  def end_huddle(huddle_id) do
    GenServer.call(__MODULE__, {:end_huddle, huddle_id})
  end

  def get_huddle(huddle_id) do
    GenServer.call(__MODULE__, {:get_huddle, huddle_id})
  end

  def get_user_huddles(user_id) do
    GenServer.call(__MODULE__, {:get_user_huddles, user_id})
  end

  def get_conversation_huddle(conversation_id) do
    GenServer.call(__MODULE__, {:get_conversation_huddle, conversation_id})
  end

  def start_screen_share(huddle_id, user_id) do
    GenServer.call(__MODULE__, {:start_screen_share, huddle_id, user_id})
  end

  def stop_screen_share(huddle_id, user_id) do
    GenServer.call(__MODULE__, {:stop_screen_share, huddle_id, user_id})
  end

  def send_to_participant(huddle_id, user_id, event, payload) do
    GenServer.cast(__MODULE__, {:send_to_participant, huddle_id, user_id, event, payload})
  end

  def active_huddles_count do
    GenServer.call(__MODULE__, :active_huddles_count)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    state = %{
      huddles: %{},              # huddle_id => %Huddle{}
      conversation_huddles: %{}, # conversation_id => huddle_id
      user_sockets: %{}          # user_id => pid
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:create_huddle, creator_id, conversation_id, name}, _from, state) do
    # Check if huddle already exists for this conversation
    case Map.get(state.conversation_huddles, conversation_id) do
      nil ->
        huddle_id = generate_huddle_id()

        huddle = %__MODULE__{
          huddle_id: huddle_id,
          conversation_id: conversation_id,
          name: name,
          creator: creator_id,
          participants: [%{user_id: creator_id, joined_at: DateTime.utc_now()}],
          screen_sharer: nil,
          created_at: DateTime.utc_now(),
          settings: %{
            video_enabled: true,
            screen_share_enabled: true,
            max_participants: 50
          }
        }

        # Store in state
        huddles = Map.put(state.huddles, huddle_id, huddle)
        conversation_huddles = Map.put(state.conversation_huddles, conversation_id, huddle_id)

        # Store in Redis
        Redis.store_huddle_session(huddle_id, huddle_to_map(huddle))

        Logger.info("Huddle #{huddle_id} created by #{creator_id} for conversation #{conversation_id}")
        {:reply, {:ok, huddle}, %{state | huddles: huddles, conversation_huddles: conversation_huddles}}

      existing_huddle_id ->
        huddle = Map.get(state.huddles, existing_huddle_id)
        {:reply, {:ok, huddle}, state}
    end
  end

  def handle_call({:join_huddle, huddle_id, user_id, _opts}, _from, state) do
    case Map.get(state.huddles, huddle_id) do
      nil ->
        # Try Redis
        case Redis.get_huddle_session(huddle_id) do
          nil ->
            {:reply, {:error, :not_found}, state}

          huddle_data ->
            huddle = map_to_huddle(huddle_data)
            huddle = add_participant(huddle, user_id)

            huddles = Map.put(state.huddles, huddle_id, huddle)
            Redis.store_huddle_session(huddle_id, huddle_to_map(huddle))

            Logger.info("User #{user_id} joined huddle #{huddle_id}")
            {:reply, {:ok, huddle}, %{state | huddles: huddles}}
        end

      huddle ->
        # Check max participants
        if length(huddle.participants) >= huddle.settings.max_participants do
          {:reply, {:error, :huddle_full}, state}
        else
          huddle = add_participant(huddle, user_id)
          huddles = Map.put(state.huddles, huddle_id, huddle)

          Redis.store_huddle_session(huddle_id, huddle_to_map(huddle))

          Logger.info("User #{user_id} joined huddle #{huddle_id}")
          {:reply, {:ok, huddle}, %{state | huddles: huddles}}
        end
    end
  end

  def handle_call({:leave_huddle, huddle_id, user_id}, _from, state) do
    case Map.get(state.huddles, huddle_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      huddle ->
        participants = Enum.reject(huddle.participants, &(&1.user_id == user_id))
        remaining_count = length(participants)

        # Clear screen share if leaving user was sharing
        screen_sharer = if huddle.screen_sharer == user_id, do: nil, else: huddle.screen_sharer

        huddle = %{huddle | participants: participants, screen_sharer: screen_sharer}
        huddles = Map.put(state.huddles, huddle_id, huddle)

        Redis.store_huddle_session(huddle_id, huddle_to_map(huddle))

        Logger.info("User #{user_id} left huddle #{huddle_id}, #{remaining_count} remaining")
        {:reply, {:ok, remaining_count}, %{state | huddles: huddles}}
    end
  end

  def handle_call({:end_huddle, huddle_id}, _from, state) do
    case Map.get(state.huddles, huddle_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      huddle ->
        huddles = Map.delete(state.huddles, huddle_id)
        conversation_huddles = Map.delete(state.conversation_huddles, huddle.conversation_id)

        Redis.delete_huddle_session(huddle_id)

        Logger.info("Huddle #{huddle_id} ended")
        {:reply, :ok, %{state | huddles: huddles, conversation_huddles: conversation_huddles}}
    end
  end

  def handle_call({:get_huddle, huddle_id}, _from, state) do
    case Map.get(state.huddles, huddle_id) do
      nil ->
        case Redis.get_huddle_session(huddle_id) do
          nil -> {:reply, {:error, :not_found}, state}
          data -> {:reply, {:ok, map_to_huddle(data)}, state}
        end

      huddle ->
        {:reply, {:ok, huddle}, state}
    end
  end

  def handle_call({:get_user_huddles, user_id}, _from, state) do
    user_huddles = state.huddles
      |> Map.values()
      |> Enum.filter(fn huddle ->
        Enum.any?(huddle.participants, &(&1.user_id == user_id))
      end)
      |> Enum.map(&huddle_summary/1)

    {:reply, user_huddles, state}
  end

  def handle_call({:get_conversation_huddle, conversation_id}, _from, state) do
    case Map.get(state.conversation_huddles, conversation_id) do
      nil ->
        {:reply, nil, state}

      huddle_id ->
        huddle = Map.get(state.huddles, huddle_id)
        {:reply, huddle, state}
    end
  end

  def handle_call({:start_screen_share, huddle_id, user_id}, _from, state) do
    case Map.get(state.huddles, huddle_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{screen_sharer: nil} = huddle ->
        huddle = %{huddle | screen_sharer: user_id}
        huddles = Map.put(state.huddles, huddle_id, huddle)
        Redis.store_huddle_session(huddle_id, huddle_to_map(huddle))

        {:reply, :ok, %{state | huddles: huddles}}

      %{screen_sharer: existing} when existing == user_id ->
        {:reply, :ok, state}

      %{screen_sharer: _existing} ->
        {:reply, {:error, :already_sharing}, state}
    end
  end

  def handle_call({:stop_screen_share, huddle_id, user_id}, _from, state) do
    case Map.get(state.huddles, huddle_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{screen_sharer: ^user_id} = huddle ->
        huddle = %{huddle | screen_sharer: nil}
        huddles = Map.put(state.huddles, huddle_id, huddle)
        Redis.store_huddle_session(huddle_id, huddle_to_map(huddle))

        {:reply, :ok, %{state | huddles: huddles}}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:active_huddles_count, _from, state) do
    {:reply, map_size(state.huddles), state}
  end

  @impl true
  def handle_cast({:send_to_participant, huddle_id, user_id, event, payload}, state) do
    # This would send via PubSub to the specific user's channel
    Phoenix.PubSub.broadcast(
      QuckChatRealtime.PubSub,
      "user:#{user_id}",
      {event, payload}
    )

    {:noreply, state}
  end

  # Private functions

  defp generate_huddle_id do
    "huddle_#{System.system_time(:millisecond)}_#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"
  end

  defp add_participant(huddle, user_id) do
    if Enum.any?(huddle.participants, &(&1.user_id == user_id)) do
      huddle
    else
      participant = %{user_id: user_id, joined_at: DateTime.utc_now()}
      %{huddle | participants: huddle.participants ++ [participant]}
    end
  end

  defp huddle_to_map(huddle) do
    %{
      "huddle_id" => huddle.huddle_id,
      "conversation_id" => huddle.conversation_id,
      "name" => huddle.name,
      "creator" => huddle.creator,
      "participants" => Enum.map(huddle.participants, fn p ->
        %{"user_id" => p.user_id, "joined_at" => DateTime.to_iso8601(p.joined_at)}
      end),
      "screen_sharer" => huddle.screen_sharer,
      "created_at" => DateTime.to_iso8601(huddle.created_at),
      "settings" => huddle.settings
    }
  end

  defp map_to_huddle(map) do
    %__MODULE__{
      huddle_id: map["huddle_id"],
      conversation_id: map["conversation_id"],
      name: map["name"],
      creator: map["creator"],
      participants: Enum.map(map["participants"], fn p ->
        %{
          user_id: p["user_id"],
          joined_at: DateTime.from_iso8601(p["joined_at"]) |> elem(1)
        }
      end),
      screen_sharer: map["screen_sharer"],
      created_at: DateTime.from_iso8601(map["created_at"]) |> elem(1),
      settings: map["settings"]
    }
  end

  defp huddle_summary(huddle) do
    %{
      huddle_id: huddle.huddle_id,
      conversation_id: huddle.conversation_id,
      name: huddle.name,
      participant_count: length(huddle.participants),
      has_screen_share: huddle.screen_sharer != nil
    }
  end
end
