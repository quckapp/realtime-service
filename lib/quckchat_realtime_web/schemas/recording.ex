defmodule QuckAppRealtimeWeb.Schemas.Recording do
  @moduledoc """
  Schemas for recording-related API operations.
  """
  alias OpenApiSpex.Schema

  defmodule StartResponse do
    @moduledoc "Response after starting recording"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RecordingStartResponse",
      description: "Response after successfully starting a call recording",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        recording_id: %Schema{type: :string, description: "Unique recording identifier"},
        started_at: %Schema{type: :string, format: :"date-time", description: "Recording start timestamp"}
      },
      required: [:success, :recording_id, :started_at],
      example: %{
        "success" => true,
        "recording_id" => "rec_1705320600_abc123",
        "started_at" => "2024-01-15T10:30:00Z"
      }
    })
  end

  defmodule StopResponse do
    @moduledoc "Response after stopping recording"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RecordingStopResponse",
      description: "Response after successfully stopping a call recording",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        recording_id: %Schema{type: :string, description: "Recording identifier"},
        duration: %Schema{type: :integer, description: "Recording duration in seconds"}
      },
      required: [:success, :recording_id, :duration],
      example: %{
        "success" => true,
        "recording_id" => "rec_1705320600_abc123",
        "duration" => 1800
      }
    })
  end

  defmodule StatusResponse do
    @moduledoc "Response for recording status query"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RecordingStatusResponse",
      description: "Response containing recording status for a call",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        recording: %Schema{type: :boolean, description: "Whether recording is currently active"},
        recording_id: %Schema{type: :string, description: "Recording ID (if recording)"},
        started_at: %Schema{type: :string, format: :"date-time", description: "Recording start time (if recording)"},
        started_by: %Schema{type: :string, description: "User ID who started recording (if recording)"}
      },
      required: [:success, :recording],
      example: %{
        "success" => true,
        "recording" => true,
        "recording_id" => "rec_1705320600_abc123",
        "started_at" => "2024-01-15T10:30:00Z",
        "started_by" => "user_456"
      }
    })
  end

  defmodule Recording do
    @moduledoc "Recording information"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Recording",
      description: "Recording information",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Unique recording identifier"},
        call_id: %Schema{type: :string, description: "Associated call ID"},
        conversation_id: %Schema{type: :string, description: "Associated conversation ID"},
        call_type: %Schema{type: :string, enum: ["audio", "video"], description: "Type of call recorded"},
        started_by: %Schema{type: :string, description: "User ID who started the recording"},
        started_at: %Schema{type: :string, format: :"date-time", description: "Recording start timestamp"},
        ended_at: %Schema{type: :string, format: :"date-time", description: "Recording end timestamp"},
        duration: %Schema{type: :integer, description: "Recording duration in seconds"},
        status: %Schema{
          type: :string,
          enum: ["recording", "processing", "completed", "failed"],
          description: "Recording status"
        }
      },
      required: [:id, :call_id, :started_by, :started_at, :status],
      example: %{
        "id" => "rec_1705320600_abc123",
        "call_id" => "call_xyz789",
        "conversation_id" => "conv_456",
        "call_type" => "video",
        "started_by" => "user_123",
        "started_at" => "2024-01-15T10:30:00Z",
        "ended_at" => "2024-01-15T11:00:00Z",
        "duration" => 1800,
        "status" => "completed"
      }
    })
  end

  defmodule ListResponse do
    @moduledoc "Response for listing recordings"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RecordingListResponse",
      description: "Response containing list of recordings",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        recordings: %Schema{
          type: :array,
          items: Recording,
          description: "List of recordings"
        },
        count: %Schema{type: :integer, description: "Number of recordings returned"}
      },
      required: [:success, :recordings, :count],
      example: %{
        "success" => true,
        "recordings" => [
          %{
            "id" => "rec_1705320600_abc123",
            "call_id" => "call_xyz789",
            "conversation_id" => "conv_456",
            "call_type" => "video",
            "started_by" => "user_123",
            "started_at" => "2024-01-15T10:30:00Z",
            "ended_at" => "2024-01-15T11:00:00Z",
            "duration" => 1800,
            "status" => "completed"
          }
        ],
        "count" => 1
      }
    })
  end

  defmodule ShowResponse do
    @moduledoc "Response for getting recording details"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RecordingShowResponse",
      description: "Response containing recording details",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        recording: Recording
      },
      required: [:success, :recording]
    })
  end

  defmodule DownloadResponse do
    @moduledoc "Response for recording download URL"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RecordingDownloadResponse",
      description: "Response containing signed download URL for recording",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        url: %Schema{type: :string, format: :uri, description: "Signed download URL"},
        expires_in: %Schema{type: :integer, description: "URL expiration time in seconds"}
      },
      required: [:success, :url, :expires_in],
      example: %{
        "success" => true,
        "url" => "https://storage.quckapp.com/recordings/rec_abc123.mp4?token=xyz...",
        "expires_in" => 3600
      }
    })
  end
end
