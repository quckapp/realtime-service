defmodule QuckAppRealtimeWeb.DeviceController do
  @moduledoc """
  Controller for managing user devices and push notification tokens.

  Handles:
  - Device registration (FCM/APNs tokens)
  - Device token updates
  - Device unregistration
  - Multi-device management
  """
  use QuckAppRealtimeWeb, :controller
  require Logger

  alias QuckAppRealtime.Mongo

  @max_devices_per_user 10

  @doc "Register a new device"
  def register(conn, params) do
    user_id = conn.assigns.user_id

    device = %{
      "device_id" => params["device_id"] || generate_device_id(),
      "platform" => params["platform"],  # ios, android, web
      "push_token" => params["push_token"],
      "token_type" => params["token_type"] || infer_token_type(params["platform"]),
      "device_name" => params["device_name"],
      "device_model" => params["device_model"],
      "os_version" => params["os_version"],
      "app_version" => params["app_version"],
      "registered_at" => DateTime.utc_now(),
      "last_active_at" => DateTime.utc_now()
    }

    case register_device(user_id, device) do
      {:ok, device} ->
        Logger.info("Device registered for user #{user_id}: #{device["device_id"]}")

        conn
        |> put_status(:created)
        |> json(%{
          success: true,
          device: %{
            device_id: device["device_id"],
            platform: device["platform"],
            registered_at: device["registered_at"]
          }
        })

      {:error, :max_devices_reached} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          success: false,
          error: "max_devices_reached",
          message: "Maximum number of devices (#{@max_devices_per_user}) reached"
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason})
    end
  end

  @doc "Update device push token"
  def update_token(conn, %{"device_id" => device_id, "push_token" => push_token} = params) do
    user_id = conn.assigns.user_id

    updates = %{
      "push_token" => push_token,
      "token_type" => params["token_type"],
      "last_active_at" => DateTime.utc_now()
    }

    case update_device(user_id, device_id, updates) do
      {:ok, _} ->
        Logger.info("Push token updated for device #{device_id}")

        conn
        |> put_status(:ok)
        |> json(%{success: true})

      {:error, :device_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "device_not_found"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason})
    end
  end

  @doc "Unregister a device"
  def unregister(conn, %{"device_id" => device_id}) do
    user_id = conn.assigns.user_id

    case unregister_device(user_id, device_id) do
      {:ok, _} ->
        Logger.info("Device unregistered: #{device_id}")

        conn
        |> put_status(:ok)
        |> json(%{success: true})

      {:error, :device_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "device_not_found"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason})
    end
  end

  @doc "List user's registered devices"
  def list(conn, _params) do
    user_id = conn.assigns.user_id

    case get_user_devices(user_id) do
      {:ok, devices} ->
        sanitized = Enum.map(devices, fn device ->
          %{
            device_id: device["device_id"],
            platform: device["platform"],
            device_name: device["device_name"],
            device_model: device["device_model"],
            registered_at: device["registered_at"],
            last_active_at: device["last_active_at"]
          }
        end)

        conn
        |> put_status(:ok)
        |> json(%{success: true, devices: sanitized})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{success: false, error: reason})
    end
  end

  @doc "Record device activity"
  def heartbeat(conn, %{"device_id" => device_id}) do
    user_id = conn.assigns.user_id

    update_device(user_id, device_id, %{
      "last_active_at" => DateTime.utc_now()
    })

    conn
    |> put_status(:ok)
    |> json(%{success: true})
  end

  # ============================================
  # Database Operations
  # ============================================

  defp register_device(user_id, device) do
    # Check current device count
    case get_user_devices(user_id) do
      {:ok, devices} when length(devices) >= @max_devices_per_user ->
        {:error, :max_devices_reached}

      {:ok, devices} ->
        # Check if device already exists
        existing = Enum.find(devices, fn d ->
          d["device_id"] == device["device_id"]
        end)

        if existing do
          # Update existing device
          update_device(user_id, device["device_id"], device)
        else
          # Add new device
          add_device(user_id, device)
        end

      {:error, :not_found} ->
        # Create new devices document
        create_devices_document(user_id, device)
    end
  end

  defp add_device(user_id, device) do
    case Mongo.command(:mongo, %{
      update: "user_devices",
      updates: [
        %{
          q: %{user_id: user_id},
          u: %{
            "$push" => %{devices: device},
            "$set" => %{updated_at: DateTime.utc_now()}
          },
          upsert: true
        }
      ]
    }) do
      {:ok, _} -> {:ok, device}
      error -> error
    end
  end

  defp create_devices_document(user_id, device) do
    doc = %{
      user_id: user_id,
      devices: [device],
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    case Mongo.insert_one(:mongo, "user_devices", doc) do
      {:ok, _} -> {:ok, device}
      error -> error
    end
  end

  defp update_device(user_id, device_id, updates) do
    # Build the update query for array element
    set_fields = Enum.map(updates, fn {k, v} ->
      {"devices.$.#{k}", v}
    end)
    |> Map.new()
    |> Map.put("updated_at", DateTime.utc_now())

    case Mongo.update_one(:mongo, "user_devices",
      %{user_id: user_id, "devices.device_id": device_id},
      %{"$set" => set_fields}
    ) do
      {:ok, %{matched_count: 1}} -> {:ok, :updated}
      {:ok, %{matched_count: 0}} -> {:error, :device_not_found}
      error -> error
    end
  end

  defp unregister_device(user_id, device_id) do
    case Mongo.update_one(:mongo, "user_devices",
      %{user_id: user_id},
      %{
        "$pull" => %{devices: %{device_id: device_id}},
        "$set" => %{updated_at: DateTime.utc_now()}
      }
    ) do
      {:ok, %{modified_count: 1}} -> {:ok, :removed}
      {:ok, %{modified_count: 0}} -> {:error, :device_not_found}
      error -> error
    end
  end

  defp get_user_devices(user_id) do
    case Mongo.find_one(:mongo, "user_devices", %{user_id: user_id}) do
      nil -> {:error, :not_found}
      doc -> {:ok, Map.get(doc, "devices", [])}
    end
  end

  # ============================================
  # Helpers
  # ============================================

  defp generate_device_id do
    "device_#{System.system_time(:millisecond)}_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end

  defp infer_token_type("ios"), do: "apns"
  defp infer_token_type("android"), do: "fcm"
  defp infer_token_type("web"), do: "fcm"
  defp infer_token_type(_), do: "unknown"
end
