defmodule QuckChatRealtime.Actors.CallSession do
  @moduledoc """
  Call Session Actor - Manages individual call state and WebRTC signaling.

  Each active call has its own supervised process that handles:
  - Call state machine (ringing -> active -> ended)
  - SDP offer/answer exchange
  - ICE candidate exchange
  - Call timeouts (ringing, max duration)
  - Participant management
  - Recording state

  State Machine:
  - :ringing - Call initiated, waiting for answer
  - :active - Call connected and ongoing
  - :on_hold - Call temporarily paused
  - :ended - Call terminated
  """
  use GenServer, restart: :transient
  require Logger

  alias QuckChatRealtime.{Redis, SignalingServer, Kafka}
  alias Phoenix.PubSub

  @ringing_timeout 60_000      # 60 seconds to answer
  @max_call_duration 3_600_000 # 1 hour max call
  @reconnect_grace 30_000      # 30 seconds to reconnect

  defstruct [
    :call_id,
    :conversation_id,
    :initiator_id,
    :call_type,
    :participants,
    :state,
    :started_at,
    :connected_at,
    :ended_at,
    :timer_ref,
    :recording,
    :metadata
  ]

  # ============================================
  # Client API
  # ============================================

  def start_link(opts) do
    call = Keyword.fetch!(opts, :call)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(call.call_id))
  end

  def via_tuple(call_id) do
    {:via, Registry, {QuckChatRealtime.CallRegistry, call_id}}
  end

  def get_state(call_id) do
    GenServer.call(via_tuple(call_id), :get_state)
  catch
    :exit, _ -> {:error, :not_found}
  end

  def answer(call_id, user_id) do
    GenServer.call(via_tuple(call_id), {:answer, user_id})
  catch
    :exit, _ -> {:error, :not_found}
  end

  def reject(call_id, user_id) do
    GenServer.call(via_tuple(call_id), {:reject, user_id})
  catch
    :exit, _ -> {:error, :not_found}
  end

  def end_call(call_id, reason, ended_by \\ nil) do
    GenServer.call(via_tuple(call_id), {:end_call, reason, ended_by})
  catch
    :exit, _ -> {:error, :not_found}
  end

  def send_offer(call_id, from_user_id, sdp_offer) do
    GenServer.cast(via_tuple(call_id), {:offer, from_user_id, sdp_offer})
  end

  def send_answer(call_id, from_user_id, sdp_answer) do
    GenServer.cast(via_tuple(call_id), {:answer_sdp, from_user_id, sdp_answer})
  end

  def send_ice_candidate(call_id, from_user_id, candidate) do
    GenServer.cast(via_tuple(call_id), {:ice, from_user_id, candidate})
  end

  def participant_joined(call_id, user_id) do
    GenServer.cast(via_tuple(call_id), {:participant_joined, user_id})
  end

  def participant_left(call_id, user_id) do
    GenServer.cast(via_tuple(call_id), {:participant_left, user_id})
  end

  def toggle_recording(call_id, enabled, user_id) do
    GenServer.call(via_tuple(call_id), {:toggle_recording, enabled, user_id})
  catch
    :exit, _ -> {:error, :not_found}
  end

  def hold(call_id, user_id) do
    GenServer.call(via_tuple(call_id), {:hold, user_id})
  catch
    :exit, _ -> {:error, :not_found}
  end

  def unhold(call_id, user_id) do
    GenServer.call(via_tuple(call_id), {:unhold, user_id})
  catch
    :exit, _ -> {:error, :not_found}
  end

  # ============================================
  # Server Callbacks
  # ============================================

  @impl true
  def init(opts) do
    call = Keyword.fetch!(opts, :call)

    # Start ringing timeout
    timer_ref = Process.send_after(self(), :ringing_timeout, @ringing_timeout)

    state = %__MODULE__{
      call_id: call.call_id,
      conversation_id: call.conversation_id,
      initiator_id: call.initiator,
      call_type: call.call_type,
      participants: init_participants(call.participants),
      state: :ringing,
      started_at: DateTime.utc_now(),
      timer_ref: timer_ref,
      recording: %{enabled: false, started_at: nil, started_by: nil},
      metadata: %{}
    }

    # Store in Redis for cross-node access
    store_in_redis(state)

    Logger.info("Call session started: #{call.call_id} (#{call.call_type})")

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state_to_map(state)}, state}
  end

  @impl true
  def handle_call({:answer, user_id}, _from, %{state: :ringing} = state) do
    if is_participant?(state, user_id) do
      # Cancel ringing timeout
      if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

      # Start max duration timer
      new_timer = Process.send_after(self(), :max_duration, @max_call_duration)

      new_state = %{state |
        state: :active,
        connected_at: DateTime.utc_now(),
        timer_ref: new_timer,
        participants: update_participant(state.participants, user_id, :connected)
      }

      store_in_redis(new_state)
      broadcast_call_event(new_state, :answered, %{user_id: user_id})
      publish_call_event(new_state, "call.answered")

      Logger.info("Call #{state.call_id} answered by #{user_id}")

      {:reply, {:ok, state_to_map(new_state)}, new_state}
    else
      {:reply, {:error, :not_participant}, state}
    end
  end

  def handle_call({:answer, _user_id}, _from, state) do
    {:reply, {:error, :invalid_state}, state}
  end

  @impl true
  def handle_call({:reject, user_id}, _from, %{state: :ringing} = state) do
    if is_participant?(state, user_id) do
      end_call_internal(state, :rejected, user_id)
    else
      {:reply, {:error, :not_participant}, state}
    end
  end

  def handle_call({:reject, _user_id}, _from, state) do
    {:reply, {:error, :invalid_state}, state}
  end

  @impl true
  def handle_call({:end_call, reason, ended_by}, _from, state) do
    end_call_internal(state, reason, ended_by)
  end

  @impl true
  def handle_call({:toggle_recording, enabled, user_id}, _from, state) do
    if state.state == :active do
      recording = if enabled do
        %{enabled: true, started_at: DateTime.utc_now(), started_by: user_id}
      else
        %{enabled: false, started_at: nil, started_by: nil}
      end

      new_state = %{state | recording: recording}
      store_in_redis(new_state)

      event = if enabled, do: :recording_started, else: :recording_stopped
      broadcast_call_event(new_state, event, %{user_id: user_id})

      {:reply, :ok, new_state}
    else
      {:reply, {:error, :call_not_active}, state}
    end
  end

  @impl true
  def handle_call({:hold, user_id}, _from, %{state: :active} = state) do
    new_state = %{state | state: :on_hold}
    store_in_redis(new_state)
    broadcast_call_event(new_state, :call_held, %{user_id: user_id})
    {:reply, :ok, new_state}
  end

  def handle_call({:hold, _user_id}, _from, state) do
    {:reply, {:error, :invalid_state}, state}
  end

  @impl true
  def handle_call({:unhold, user_id}, _from, %{state: :on_hold} = state) do
    new_state = %{state | state: :active}
    store_in_redis(new_state)
    broadcast_call_event(new_state, :call_resumed, %{user_id: user_id})
    {:reply, :ok, new_state}
  end

  def handle_call({:unhold, _user_id}, _from, state) do
    {:reply, {:error, :invalid_state}, state}
  end

  @impl true
  def handle_cast({:offer, from_user_id, sdp_offer}, state) do
    broadcast_to_others(state, from_user_id, {:sdp_offer, state.call_id, from_user_id, sdp_offer})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:answer_sdp, from_user_id, sdp_answer}, state) do
    broadcast_to_others(state, from_user_id, {:sdp_answer, state.call_id, from_user_id, sdp_answer})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:ice, from_user_id, candidate}, state) do
    broadcast_to_others(state, from_user_id, {:ice_candidate, state.call_id, from_user_id, candidate})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:participant_joined, user_id}, state) do
    new_state = %{state |
      participants: update_participant(state.participants, user_id, :connected)
    }
    store_in_redis(new_state)
    broadcast_call_event(new_state, :participant_joined, %{user_id: user_id})
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:participant_left, user_id}, state) do
    new_participants = update_participant(state.participants, user_id, :disconnected)
    connected_count = count_connected_participants(new_participants)

    new_state = %{state | participants: new_participants}
    store_in_redis(new_state)
    broadcast_call_event(new_state, :participant_left, %{user_id: user_id})

    # End call if no connected participants remain
    if connected_count == 0 do
      {:stop, :normal, new_state}
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(:ringing_timeout, %{state: :ringing} = state) do
    Logger.info("Call #{state.call_id} timed out (no answer)")
    end_call_internal(state, :missed, nil)
  end

  def handle_info(:ringing_timeout, state) do
    # Call was answered, ignore
    {:noreply, state}
  end

  @impl true
  def handle_info(:max_duration, state) do
    Logger.info("Call #{state.call_id} reached maximum duration")
    end_call_internal(state, :max_duration, nil)
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Call session terminated: #{state.call_id}, reason: #{inspect(reason)}")

    # Clean up Redis
    Redis.delete_call_session(state.call_id)

    # Final event
    if state.state != :ended do
      publish_call_event(state, "call.ended")
    end

    :ok
  end

  # ============================================
  # Private Functions
  # ============================================

  defp end_call_internal(state, reason, ended_by) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    duration = calculate_duration(state)

    new_state = %{state |
      state: :ended,
      ended_at: DateTime.utc_now()
    }

    # Clean up Redis
    Redis.delete_call_session(state.call_id)

    # Broadcast end event
    broadcast_call_event(new_state, :ended, %{
      reason: reason,
      ended_by: ended_by,
      duration: duration
    })

    publish_call_event(new_state, "call.ended")

    Logger.info("Call #{state.call_id} ended: #{reason}, duration: #{duration}s")

    {:stop, :normal, {:ok, %{reason: reason, duration: duration}}, new_state}
  end

  defp init_participants(participant_ids) when is_list(participant_ids) do
    Enum.map(participant_ids, fn id ->
      %{
        user_id: id,
        status: :invited,
        joined_at: nil,
        left_at: nil,
        audio_enabled: true,
        video_enabled: true
      }
    end)
  end

  defp is_participant?(state, user_id) do
    Enum.any?(state.participants, &(&1.user_id == user_id))
  end

  defp update_participant(participants, user_id, status) do
    Enum.map(participants, fn p ->
      if p.user_id == user_id do
        case status do
          :connected -> %{p | status: :connected, joined_at: DateTime.utc_now()}
          :disconnected -> %{p | status: :disconnected, left_at: DateTime.utc_now()}
          _ -> %{p | status: status}
        end
      else
        p
      end
    end)
  end

  defp count_connected_participants(participants) do
    Enum.count(participants, &(&1.status == :connected))
  end

  defp calculate_duration(%{connected_at: nil}), do: 0
  defp calculate_duration(%{connected_at: connected_at}) do
    DateTime.diff(DateTime.utc_now(), connected_at, :second)
  end

  defp store_in_redis(state) do
    Redis.store_call_session(state.call_id, state_to_map(state))
  end

  defp state_to_map(state) do
    %{
      call_id: state.call_id,
      conversation_id: state.conversation_id,
      initiator_id: state.initiator_id,
      call_type: state.call_type,
      participants: state.participants,
      state: state.state,
      started_at: state.started_at && DateTime.to_iso8601(state.started_at),
      connected_at: state.connected_at && DateTime.to_iso8601(state.connected_at),
      recording: state.recording
    }
  end

  defp broadcast_call_event(state, event, data) do
    Enum.each(state.participants, fn p ->
      PubSub.broadcast(
        QuckChatRealtime.PubSub,
        "user:#{p.user_id}",
        {:call_event, state.call_id, event, data}
      )
    end)
  end

  defp broadcast_to_others(state, from_user_id, message) do
    Enum.each(state.participants, fn p ->
      if p.user_id != from_user_id do
        PubSub.broadcast(QuckChatRealtime.PubSub, "user:#{p.user_id}", message)
      end
    end)
  end

  defp publish_call_event(state, event_type) do
    event = %{
      type: event_type,
      call_id: state.call_id,
      conversation_id: state.conversation_id,
      call_type: state.call_type,
      participants: Enum.map(state.participants, & &1.user_id),
      state: state.state,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Kafka.Producer.publish("call-events", state.call_id, event)
  rescue
    _ -> :ok
  end
end
