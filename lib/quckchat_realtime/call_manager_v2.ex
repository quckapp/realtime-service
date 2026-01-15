defmodule QuckAppRealtime.CallManagerV2 do
  @moduledoc """
  WhatsApp-Style Call Manager.

  Manages voice/video calls with:
  - Call state machine (initiating → ringing → active → ended)
  - WebRTC signaling coordination
  - Call timeout handling
  - Multi-party call support
  - Call recording metadata

  Each active call is tracked in ETS for O(1) lookups.
  Call history is persisted to MongoDB Atlas.
  """
  use GenServer
  require Logger

  alias QuckAppRealtime.{Mongo, PresenceManager, NestJSClient, MessageRouter}
  alias QuckAppRealtime.Actors.UserSession

  @calls_table :active_calls
  @call_timeout 60_000         # 60 seconds to answer
  @max_call_duration 14_400_000  # 4 hours

  defmodule CallState do
    @moduledoc "State for an active call"
    defstruct [
      :call_id,
      :conversation_id,
      :initiator_id,
      :call_type,
      :status,
      :participants,
      :created_at,
      :answered_at,
      :ice_servers,
      :timeout_ref,
      :db_record_id
    ]
  end

  # ============================================
  # Client API
  # ============================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Initiate a new call"
  def initiate_call(initiator_id, conversation_id, participant_ids, call_type) do
    GenServer.call(__MODULE__, {:initiate, initiator_id, conversation_id, participant_ids, call_type})
  end

  @doc "Answer a call"
  def answer_call(call_id, user_id) do
    GenServer.call(__MODULE__, {:answer, call_id, user_id})
  end

  @doc "Reject a call"
  def reject_call(call_id, user_id, reason \\ "rejected") do
    GenServer.call(__MODULE__, {:reject, call_id, user_id, reason})
  end

  @doc "End a call"
  def end_call(call_id, user_id) do
    GenServer.call(__MODULE__, {:end_call, call_id, user_id})
  end

  @doc "Get call state"
  def get_call(call_id) do
    case :ets.lookup(@calls_table, call_id) do
      [{^call_id, call}] -> {:ok, call}
      [] -> {:error, :not_found}
    end
  end

  @doc "Forward WebRTC signal"
  def forward_signal(call_id, from_user_id, to_user_id, signal_type, payload) do
    GenServer.cast(__MODULE__, {:signal, call_id, from_user_id, to_user_id, signal_type, payload})
  end

  @doc "Toggle audio/video"
  def toggle_media(call_id, user_id, media_type, enabled) do
    GenServer.cast(__MODULE__, {:toggle_media, call_id, user_id, media_type, enabled})
  end

  # ============================================
  # Server Callbacks
  # ============================================

  @impl true
  def init(_opts) do
    :ets.new(@calls_table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:initiate, initiator_id, conversation_id, participant_ids, call_type}, _from, state) do
    call_id = generate_call_id()

    participants = [
      %{user_id: initiator_id, status: "connected", joined_at: DateTime.utc_now()}
      | Enum.map(participant_ids, &%{user_id: &1, status: "ringing", joined_at: nil})
    ]

    # Set timeout for unanswered call
    timeout_ref = Process.send_after(self(), {:call_timeout, call_id}, @call_timeout)

    call = %CallState{
      call_id: call_id,
      conversation_id: conversation_id,
      initiator_id: initiator_id,
      call_type: call_type,
      status: "ringing",
      participants: participants,
      created_at: DateTime.utc_now(),
      ice_servers: get_ice_servers(),
      timeout_ref: timeout_ref
    }

    # Store in ETS
    :ets.insert(@calls_table, {call_id, call})

    # Persist to MySQL
    Task.start(fn ->
      persist_call_record(call)
    end)

    # Notify participants
    notify_incoming_call(call, participant_ids)

    {:reply, {:ok, call}, state}
  end

  @impl true
  def handle_call({:answer, call_id, user_id}, _from, state) do
    case get_call(call_id) do
      {:ok, call} ->
        # Cancel timeout
        if call.timeout_ref, do: Process.cancel_timer(call.timeout_ref)

        # Update participant status
        participants = Enum.map(call.participants, fn p ->
          if p.user_id == user_id do
            %{p | status: "connected", joined_at: DateTime.utc_now()}
          else
            p
          end
        end)

        updated_call = %{call |
          status: "active",
          participants: participants,
          answered_at: DateTime.utc_now(),
          timeout_ref: nil
        }

        :ets.insert(@calls_table, {call_id, updated_call})

        # Notify other participants
        notify_call_answered(updated_call, user_id)

        # Update DB record
        update_call_record(call_id, %{status: "active", answered_at: DateTime.utc_now()})

        {:reply, {:ok, updated_call}, state}

      {:error, :not_found} ->
        {:reply, {:error, :call_not_found}, state}
    end
  end

  @impl true
  def handle_call({:reject, call_id, user_id, reason}, _from, state) do
    case get_call(call_id) do
      {:ok, call} ->
        # Update participant status
        participants = Enum.map(call.participants, fn p ->
          if p.user_id == user_id do
            %{p | status: "rejected"}
          else
            p
          end
        end)

        # Check if all non-initiator participants rejected
        all_rejected = participants
          |> Enum.reject(&(&1.user_id == call.initiator_id))
          |> Enum.all?(&(&1.status in ["rejected", "missed"]))

        if all_rejected do
          # End the call
          end_call_internal(call_id, "rejected")
          {:reply, {:ok, :call_ended}, state}
        else
          updated_call = %{call | participants: participants}
          :ets.insert(@calls_table, {call_id, updated_call})

          # Notify initiator
          notify_call_rejected(call, user_id, reason)

          {:reply, {:ok, updated_call}, state}
        end

      {:error, :not_found} ->
        {:reply, {:error, :call_not_found}, state}
    end
  end

  @impl true
  def handle_call({:end_call, call_id, user_id}, _from, state) do
    case get_call(call_id) do
      {:ok, call} ->
        end_call_internal(call_id, "completed")
        notify_call_ended(call, user_id)
        {:reply, :ok, state}

      {:error, :not_found} ->
        {:reply, {:error, :call_not_found}, state}
    end
  end

  @impl true
  def handle_cast({:signal, call_id, from_user_id, to_user_id, signal_type, payload}, state) do
    # Forward WebRTC signal to target user
    signal = %{
      type: "webrtc:#{signal_type}",
      data: %{
        call_id: call_id,
        from: from_user_id,
        payload: payload
      }
    }

    if UserSession.online?(to_user_id) do
      UserSession.send_message(to_user_id, signal)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:toggle_media, call_id, user_id, media_type, enabled}, state) do
    case get_call(call_id) do
      {:ok, call} ->
        # Notify all participants
        Enum.each(call.participants, fn p ->
          if p.user_id != user_id and UserSession.online?(p.user_id) do
            UserSession.send_message(p.user_id, %{
              type: "call:media_toggled",
              data: %{
                call_id: call_id,
                user_id: user_id,
                media_type: media_type,
                enabled: enabled
              }
            })
          end
        end)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:call_timeout, call_id}, state) do
    case get_call(call_id) do
      {:ok, %{status: "ringing"} = call} ->
        Logger.info("Call #{call_id} timed out (unanswered)")
        end_call_internal(call_id, "missed")
        notify_call_missed(call)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  # ============================================
  # Private Functions
  # ============================================

  defp end_call_internal(call_id, reason) do
    case get_call(call_id) do
      {:ok, call} ->
        if call.timeout_ref, do: Process.cancel_timer(call.timeout_ref)

        # Calculate duration
        duration = if call.answered_at do
          DateTime.diff(DateTime.utc_now(), call.answered_at, :second)
        else
          0
        end

        # Remove from ETS
        :ets.delete(@calls_table, call_id)

        # Update DB record
        update_call_record(call_id, %{
          status: "ended",
          end_reason: reason,
          ended_at: DateTime.utc_now(),
          duration_seconds: duration
        })

      _ ->
        :ok
    end
  end

  defp notify_incoming_call(call, participant_ids) do
    Enum.each(participant_ids, fn user_id ->
      message = %{
        type: "call:incoming",
        data: %{
          call_id: call.call_id,
          call_type: call.call_type,
          conversation_id: call.conversation_id,
          initiator_id: call.initiator_id,
          ice_servers: call.ice_servers
        }
      }

      if UserSession.online?(user_id) do
        UserSession.send_message(user_id, message)
      else
        # Send push notification for offline users
        send_call_push_notification(user_id, call)
      end
    end)
  end

  defp notify_call_answered(call, answerer_id) do
    Enum.each(call.participants, fn p ->
      if p.user_id != answerer_id and UserSession.online?(p.user_id) do
        UserSession.send_message(p.user_id, %{
          type: "call:answered",
          data: %{
            call_id: call.call_id,
            user_id: answerer_id
          }
        })
      end
    end)
  end

  defp notify_call_rejected(call, rejecter_id, reason) do
    UserSession.send_message(call.initiator_id, %{
      type: "call:rejected",
      data: %{
        call_id: call.call_id,
        user_id: rejecter_id,
        reason: reason
      }
    })
  end

  defp notify_call_ended(call, ended_by) do
    Enum.each(call.participants, fn p ->
      if UserSession.online?(p.user_id) do
        UserSession.send_message(p.user_id, %{
          type: "call:ended",
          data: %{
            call_id: call.call_id,
            ended_by: ended_by
          }
        })
      end
    end)
  end

  defp notify_call_missed(call) do
    Enum.each(call.participants, fn p ->
      if p.user_id != call.initiator_id do
        # Send push notification for missed call
        send_missed_call_notification(p.user_id, call)
      end
    end)

    # Notify initiator that call was missed
    if UserSession.online?(call.initiator_id) do
      UserSession.send_message(call.initiator_id, %{
        type: "call:missed",
        data: %{call_id: call.call_id}
      })
    end
  end

  defp persist_call_record(call) do
    # Persist to MongoDB Atlas
    Mongo.insert_call(%{
      "callId" => call.call_id,
      "conversationId" => call.conversation_id,
      "initiatorId" => call.initiator_id,
      "callType" => call.call_type,
      "status" => call.status,
      "participants" => Enum.map(call.participants, fn p ->
        %{
          "userId" => p.user_id,
          "status" => p.status,
          "joinedAt" => p.joined_at
        }
      end),
      "initiatedAt" => call.created_at
    })
  end

  defp update_call_record(call_id, updates) do
    Task.start(fn ->
      # Convert Elixir map keys to MongoDB format
      mongo_updates = updates
        |> Enum.map(fn
          {:status, v} -> {"status", v}
          {:answered_at, v} -> {"answeredAt", v}
          {:ended_at, v} -> {"endedAt", v}
          {:end_reason, v} -> {"endReason", v}
          {:duration_seconds, v} -> {"durationSeconds", v}
          {k, v} -> {to_string(k), v}
        end)
        |> Map.new()

      Mongo.update_call(call_id, mongo_updates)
    end)
  end

  defp send_call_push_notification(user_id, call) do
    Task.start(fn ->
      NestJSClient.send_call_notification(
        [user_id],
        "Incoming Call",
        call.call_type,
        call.call_id,
        call.conversation_id
      )
    end)
  end

  defp send_missed_call_notification(user_id, call) do
    Task.start(fn ->
      NestJSClient.send_push_notification(
        [user_id],
        "Missed Call",
        "You missed a #{call.call_type} call",
        %{type: "missed_call", call_id: call.call_id}
      )
    end)
  end

  defp generate_call_id do
    "call_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
  end

  defp get_ice_servers do
    config = Application.get_env(:quckapp_realtime, :ice_servers, [])

    stun = Keyword.get(config, :stun, "stun:stun.l.google.com:19302")
    turn_url = Keyword.get(config, :turn_url)
    turn_username = Keyword.get(config, :turn_username)
    turn_credential = Keyword.get(config, :turn_credential)

    servers = [%{urls: stun}]

    if turn_url && turn_username && turn_credential do
      servers ++ [%{
        urls: turn_url,
        username: turn_username,
        credential: turn_credential
      }]
    else
      servers
    end
  end
end
