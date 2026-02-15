defmodule QuckAppRealtimeWeb.Schemas.Device do
  @moduledoc """
  Schemas for device management API operations.
  """
  alias OpenApiSpex.Schema

  defmodule RegisterRequest do
    @moduledoc "Request to register a new device"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DeviceRegisterRequest",
      description: "Request to register a new device for push notifications",
      type: :object,
      properties: %{
        device_id: %Schema{type: :string, description: "Unique device identifier (auto-generated if not provided)"},
        platform: %Schema{
          type: :string,
          enum: ["ios", "android", "web"],
          description: "Device platform"
        },
        push_token: %Schema{type: :string, description: "Push notification token (FCM/APNs)"},
        token_type: %Schema{
          type: :string,
          enum: ["fcm", "apns", "web_push"],
          description: "Type of push token (inferred from platform if not provided)"
        },
        device_name: %Schema{type: :string, description: "Human-readable device name"},
        device_model: %Schema{type: :string, description: "Device model (e.g., iPhone 15, Pixel 8)"},
        os_version: %Schema{type: :string, description: "Operating system version"},
        app_version: %Schema{type: :string, description: "Application version"}
      },
      required: [:platform, :push_token],
      example: %{
        "platform" => "ios",
        "push_token" => "abc123...xyz789",
        "token_type" => "apns",
        "device_name" => "John's iPhone",
        "device_model" => "iPhone 15 Pro",
        "os_version" => "17.2",
        "app_version" => "2.1.0"
      }
    })
  end

  defmodule RegisterResponse do
    @moduledoc "Response after registering a device"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DeviceRegisterResponse",
      description: "Response after successfully registering a device",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        device: %Schema{
          type: :object,
          properties: %{
            device_id: %Schema{type: :string, description: "Unique device identifier"},
            platform: %Schema{type: :string, description: "Device platform"},
            registered_at: %Schema{type: :string, format: :"date-time", description: "Registration timestamp"}
          }
        }
      },
      required: [:success, :device],
      example: %{
        "success" => true,
        "device" => %{
          "device_id" => "device_1705320600_abc123",
          "platform" => "ios",
          "registered_at" => "2024-01-15T10:30:00Z"
        }
      }
    })
  end

  defmodule Device do
    @moduledoc "Device information"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Device",
      description: "Registered device information",
      type: :object,
      properties: %{
        device_id: %Schema{type: :string, description: "Unique device identifier"},
        platform: %Schema{type: :string, enum: ["ios", "android", "web"], description: "Device platform"},
        device_name: %Schema{type: :string, description: "Human-readable device name"},
        device_model: %Schema{type: :string, description: "Device model"},
        registered_at: %Schema{type: :string, format: :"date-time", description: "Registration timestamp"},
        last_active_at: %Schema{type: :string, format: :"date-time", description: "Last activity timestamp"}
      },
      required: [:device_id, :platform],
      example: %{
        "device_id" => "device_1705320600_abc123",
        "platform" => "ios",
        "device_name" => "John's iPhone",
        "device_model" => "iPhone 15 Pro",
        "registered_at" => "2024-01-15T10:30:00Z",
        "last_active_at" => "2024-01-15T12:45:00Z"
      }
    })
  end

  defmodule ListResponse do
    @moduledoc "Response for listing user's devices"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DeviceListResponse",
      description: "Response containing list of user's registered devices",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean},
        devices: %Schema{
          type: :array,
          items: Device,
          description: "List of registered devices"
        }
      },
      required: [:success, :devices],
      example: %{
        "success" => true,
        "devices" => [
          %{
            "device_id" => "device_1705320600_abc123",
            "platform" => "ios",
            "device_name" => "John's iPhone",
            "device_model" => "iPhone 15 Pro",
            "registered_at" => "2024-01-15T10:30:00Z",
            "last_active_at" => "2024-01-15T12:45:00Z"
          },
          %{
            "device_id" => "device_1705320700_def456",
            "platform" => "android",
            "device_name" => "John's Pixel",
            "device_model" => "Pixel 8",
            "registered_at" => "2024-01-15T10:31:40Z",
            "last_active_at" => "2024-01-15T11:00:00Z"
          }
        ]
      }
    })
  end

  defmodule UpdateTokenRequest do
    @moduledoc "Request to update device push token"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DeviceUpdateTokenRequest",
      description: "Request to update a device's push notification token",
      type: :object,
      properties: %{
        push_token: %Schema{type: :string, description: "New push notification token"},
        token_type: %Schema{
          type: :string,
          enum: ["fcm", "apns", "web_push"],
          description: "Type of push token"
        }
      },
      required: [:push_token],
      example: %{
        "push_token" => "new_token_xyz789...",
        "token_type" => "apns"
      }
    })
  end

  defmodule HeartbeatResponse do
    @moduledoc "Response for device heartbeat"
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DeviceHeartbeatResponse",
      description: "Response after recording device heartbeat",
      type: :object,
      properties: %{
        success: %Schema{type: :boolean}
      },
      required: [:success],
      example: %{
        "success" => true
      }
    })
  end
end
