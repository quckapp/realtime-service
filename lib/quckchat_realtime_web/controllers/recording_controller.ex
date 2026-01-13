defmodule QuckChatRealtimeWeb.RecordingController do
  @moduledoc """
  Controller for call/huddle recording management.

  Handles:
  - Start/stop recording
  - Recording status queries
  - Recording storage management
  - Recording access permissions
  """
  use QuckChatRealtimeWeb, :controller
  require Logger

  alias QuckChatRealtime.{Mongo, Redis}
  alias QuckChatRealtime.Actors.CallSession

  @doc "Start recording a call"
  def start(conn, %{"call_id" => call_id}) do
    user_id = conn.assigns.user_id

    case CallSession.toggle_recording(call_id, true, user_id) do
      :ok ->
        # Create recording record
        recording = create_recording(call_id, user_id)

        Logger.info("Recording started for call #{call_id} by #{user_id}")

        conn
        |> put_status(:ok)
        |> json(%{
          success: true,
          recording_id: recording["_id"],
          started_at: recording["started_at"]
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "call_not_found"})

      {:error, :call_not_active} ->
        conn
        |> put_status(:conflict)
        |> json(%{success: false, error: "call_not_active"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason})
    end
  end

  @doc "Stop recording a call"
  def stop(conn, %{"call_id" => call_id}) do
    user_id = conn.assigns.user_id

    case CallSession.toggle_recording(call_id, false, user_id) do
      :ok ->
        # Finalize recording record
        recording = finalize_recording(call_id, user_id)

        Logger.info("Recording stopped for call #{call_id}")

        conn
        |> put_status(:ok)
        |> json(%{
          success: true,
          recording_id: recording["_id"],
          duration: recording["duration"]
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason})
    end
  end

  @doc "Get recording status for a call"
  def status(conn, %{"call_id" => call_id}) do
    case get_active_recording(call_id) do
      {:ok, recording} ->
        conn
        |> put_status(:ok)
        |> json(%{
          success: true,
          recording: true,
          recording_id: recording["_id"],
          started_at: recording["started_at"],
          started_by: recording["started_by"]
        })

      {:error, :not_found} ->
        conn
        |> put_status(:ok)
        |> json(%{success: true, recording: false})
    end
  end

  @doc "List recordings for a conversation"
  def list(conn, %{"conversation_id" => conversation_id} = params) do
    user_id = conn.assigns.user_id
    limit = Map.get(params, "limit", 20) |> ensure_integer()
    offset = Map.get(params, "offset", 0) |> ensure_integer()

    # Verify user has access to conversation
    case verify_conversation_access(user_id, conversation_id) do
      :ok ->
        recordings = get_conversation_recordings(conversation_id, limit, offset)

        conn
        |> put_status(:ok)
        |> json(%{
          success: true,
          recordings: recordings,
          count: length(recordings)
        })

      {:error, :not_authorized} ->
        conn
        |> put_status(:forbidden)
        |> json(%{success: false, error: "not_authorized"})
    end
  end

  @doc "Get recording details"
  def show(conn, %{"recording_id" => recording_id}) do
    user_id = conn.assigns.user_id

    case get_recording(recording_id) do
      {:ok, recording} ->
        # Verify access
        if can_access_recording?(user_id, recording) do
          conn
          |> put_status(:ok)
          |> json(%{success: true, recording: sanitize_recording(recording)})
        else
          conn
          |> put_status(:forbidden)
          |> json(%{success: false, error: "not_authorized"})
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "recording_not_found"})
    end
  end

  @doc "Delete a recording"
  def delete(conn, %{"recording_id" => recording_id}) do
    user_id = conn.assigns.user_id

    case get_recording(recording_id) do
      {:ok, recording} ->
        # Only the user who started the recording can delete it
        if recording["started_by"] == user_id do
          delete_recording(recording_id)

          conn
          |> put_status(:ok)
          |> json(%{success: true})
        else
          conn
          |> put_status(:forbidden)
          |> json(%{success: false, error: "not_authorized"})
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "recording_not_found"})
    end
  end

  @doc "Get signed URL for recording download"
  def download_url(conn, %{"recording_id" => recording_id}) do
    user_id = conn.assigns.user_id

    case get_recording(recording_id) do
      {:ok, recording} ->
        if can_access_recording?(user_id, recording) do
          url = generate_download_url(recording)

          conn
          |> put_status(:ok)
          |> json(%{
            success: true,
            url: url,
            expires_in: 3600
          })
        else
          conn
          |> put_status(:forbidden)
          |> json(%{success: false, error: "not_authorized"})
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "recording_not_found"})
    end
  end

  # ============================================
  # Database Operations
  # ============================================

  defp create_recording(call_id, user_id) do
    # Get call details
    call_data = case Redis.get_call_session(call_id) do
      nil -> %{}
      data -> data
    end

    recording = %{
      "_id" => generate_recording_id(),
      "call_id" => call_id,
      "conversation_id" => call_data["conversation_id"],
      "call_type" => call_data["call_type"],
      "participants" => call_data["participants"] || [],
      "started_by" => user_id,
      "started_at" => DateTime.utc_now(),
      "ended_at" => nil,
      "duration" => nil,
      "status" => "recording",
      "storage_path" => nil,
      "file_size" => nil,
      "created_at" => DateTime.utc_now()
    }

    Mongo.insert_one(:mongo, "recordings", recording)

    # Track in Redis for quick lookup
    Redis.command(["SET", "recording:active:#{call_id}", Jason.encode!(recording), "EX", "7200"])

    recording
  end

  defp finalize_recording(call_id, _user_id) do
    # Get active recording
    case get_active_recording(call_id) do
      {:ok, recording} ->
        now = DateTime.utc_now()
        duration = DateTime.diff(now, recording["started_at"], :second)

        updates = %{
          "ended_at" => now,
          "duration" => duration,
          "status" => "completed"
        }

        Mongo.update_one(:mongo, "recordings",
          %{"_id" => recording["_id"]},
          %{"$set" => updates}
        )

        # Clear Redis
        Redis.command(["DEL", "recording:active:#{call_id}"])

        Map.merge(recording, updates)

      {:error, :not_found} ->
        %{}
    end
  end

  defp get_active_recording(call_id) do
    case Redis.command(["GET", "recording:active:#{call_id}"]) do
      {:ok, nil} ->
        # Fallback to MongoDB
        case Mongo.find_one(:mongo, "recordings",
          %{call_id: call_id, status: "recording"}
        ) do
          nil -> {:error, :not_found}
          recording -> {:ok, recording}
        end

      {:ok, data} ->
        {:ok, Jason.decode!(data)}
    end
  end

  defp get_recording(recording_id) do
    case Mongo.find_one(:mongo, "recordings", %{"_id" => recording_id}) do
      nil -> {:error, :not_found}
      recording -> {:ok, recording}
    end
  end

  defp get_conversation_recordings(conversation_id, limit, offset) do
    Mongo.find(:mongo, "recordings",
      %{conversation_id: conversation_id, status: "completed"},
      sort: %{created_at: -1},
      limit: limit,
      skip: offset
    )
    |> Enum.to_list()
    |> Enum.map(&sanitize_recording/1)
  end

  defp delete_recording(recording_id) do
    # In production, also delete the actual file from storage
    Mongo.delete_one(:mongo, "recordings", %{"_id" => recording_id})
  end

  # ============================================
  # Helpers
  # ============================================

  defp verify_conversation_access(user_id, conversation_id) do
    case Mongo.find_one(:mongo, "conversations", %{"_id" => conversation_id}) do
      nil ->
        {:error, :not_found}

      conversation ->
        participants = conversation["participants"] || []
        participant_ids = Enum.map(participants, & &1["userId"] |> to_string())

        if user_id in participant_ids do
          :ok
        else
          {:error, :not_authorized}
        end
    end
  end

  defp can_access_recording?(user_id, recording) do
    participants = recording["participants"] || []
    user_id in participants || recording["started_by"] == user_id
  end

  defp sanitize_recording(recording) do
    %{
      id: recording["_id"],
      call_id: recording["call_id"],
      conversation_id: recording["conversation_id"],
      call_type: recording["call_type"],
      started_by: recording["started_by"],
      started_at: recording["started_at"],
      ended_at: recording["ended_at"],
      duration: recording["duration"],
      status: recording["status"]
    }
  end

  defp generate_download_url(recording) do
    # In production, generate signed URL from storage provider (S3, Azure Blob, etc.)
    storage_path = recording["storage_path"]

    if storage_path do
      config = Application.get_env(:quckchat_realtime, :storage, [])
      base_url = Keyword.get(config, :base_url, "https://storage.quikapp.com")
      "#{base_url}/#{storage_path}?token=#{generate_access_token(recording["_id"])}"
    else
      nil
    end
  end

  defp generate_access_token(recording_id) do
    # Simple token generation - in production use proper JWT
    data = "#{recording_id}:#{System.system_time(:second)}"
    :crypto.mac(:hmac, :sha256, "secret_key", data)
    |> Base.url_encode64(padding: false)
  end

  defp generate_recording_id do
    "rec_#{System.system_time(:millisecond)}_#{:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)}"
  end

  defp ensure_integer(value) when is_integer(value), do: value
  defp ensure_integer(value) when is_binary(value), do: String.to_integer(value)
  defp ensure_integer(_), do: 0
end
