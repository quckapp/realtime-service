defmodule QuckChatRealtime.Providers.APNs do
  @moduledoc """
  Apple Push Notification Service (APNs) Provider.

  Handles:
  - Standard push notifications for iOS
  - VoIP push notifications for incoming calls
  - Silent notifications for background updates
  - Token-based authentication (JWT)
  """
  use GenServer
  require Logger

  @apns_production_url "https://api.push.apple.com"
  @apns_sandbox_url "https://api.sandbox.push.apple.com"
  @token_refresh_interval 3000_000  # 50 minutes (tokens valid for 1 hour)

  defstruct [:team_id, :key_id, :private_key, :bundle_id, :environment, :jwt_token, :token_generated_at]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ============================================
  # Public API
  # ============================================

  @doc "Send a standard push notification"
  def send(device_token, notification, opts \\ []) do
    GenServer.cast(__MODULE__, {:send, device_token, notification, :alert, opts})
  end

  @doc "Send a VoIP push notification (for incoming calls)"
  def send_voip(device_token, notification, opts \\ []) do
    GenServer.cast(__MODULE__, {:send, device_token, notification, :voip, opts})
  end

  @doc "Send a silent/background notification"
  def send_silent(device_token, data, opts \\ []) do
    GenServer.cast(__MODULE__, {:send_silent, device_token, data, opts})
  end

  @doc "Send bulk notifications"
  def send_bulk(device_tokens, notification, opts \\ []) do
    Enum.each(device_tokens, fn token ->
      send(token, notification, opts)
    end)
    :ok
  end

  # ============================================
  # Server Callbacks
  # ============================================

  @impl true
  def init(_opts) do
    config = Application.get_env(:quckchat_realtime, :apns, [])

    state = %__MODULE__{
      team_id: Keyword.get(config, :team_id),
      key_id: Keyword.get(config, :key_id),
      private_key: load_private_key(Keyword.get(config, :key_path)),
      bundle_id: Keyword.get(config, :bundle_id),
      environment: Keyword.get(config, :environment, :sandbox),
      jwt_token: nil,
      token_generated_at: nil
    }

    # Schedule token refresh
    if state.private_key do
      schedule_token_refresh()
    end

    {:ok, state}
  end

  @impl true
  def handle_cast({:send, device_token, notification, push_type, opts}, state) do
    state = ensure_valid_token(state)

    if state.jwt_token do
      do_send_notification(device_token, notification, push_type, opts, state)
    else
      Logger.warning("APNs not configured, skipping notification")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_silent, device_token, data, opts}, state) do
    state = ensure_valid_token(state)

    if state.jwt_token do
      do_send_silent(device_token, data, opts, state)
    else
      Logger.warning("APNs not configured, skipping silent notification")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh_token, state) do
    new_state = generate_jwt_token(state)
    schedule_token_refresh()
    {:noreply, new_state}
  end

  # ============================================
  # Private Functions
  # ============================================

  defp do_send_notification(device_token, notification, push_type, opts, state) do
    url = build_url(device_token, state)
    headers = build_headers(push_type, opts, state)

    payload = %{
      "aps" => %{
        "alert" => %{
          "title" => notification.title,
          "body" => notification.body
        },
        "sound" => Keyword.get(opts, :sound, "default"),
        "badge" => Keyword.get(opts, :badge),
        "category" => Keyword.get(opts, :category),
        "thread-id" => Keyword.get(opts, :thread_id)
      }
    }

    # Add custom data
    payload = if notification.data do
      Map.merge(payload, notification.data)
    else
      payload
    end

    send_request(url, headers, payload, device_token)
  end

  defp do_send_silent(device_token, data, opts, state) do
    url = build_url(device_token, state)
    headers = build_headers(:background, opts, state)

    payload = %{
      "aps" => %{
        "content-available" => 1
      }
    }

    payload = Map.merge(payload, data)

    send_request(url, headers, payload, device_token)
  end

  defp send_request(url, headers, payload, device_token) do
    case Req.post(url,
      json: payload,
      headers: headers,
      connect_options: [transport_opts: [versions: [:"tlsv1.2"]]]
    ) do
      {:ok, %{status: 200}} ->
        :telemetry.execute([:notification, :apns, :sent], %{count: 1}, %{})
        Logger.debug("APNs notification sent to #{String.slice(device_token, 0..10)}...")
        :ok

      {:ok, %{status: 410}} ->
        # Device token is no longer valid
        Logger.info("APNs device token invalid: #{String.slice(device_token, 0..10)}...")
        {:error, :invalid_token}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("APNs notification failed: #{status} - #{inspect(body)}")
        :telemetry.execute([:notification, :apns, :failed], %{count: 1}, %{status: status})
        {:error, body}

      {:error, reason} ->
        Logger.error("APNs request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_url(device_token, state) do
    base_url = if state.environment == :production do
      @apns_production_url
    else
      @apns_sandbox_url
    end

    "#{base_url}/3/device/#{device_token}"
  end

  defp build_headers(push_type, opts, state) do
    topic = case push_type do
      :voip -> "#{state.bundle_id}.voip"
      :complication -> "#{state.bundle_id}.complication"
      _ -> state.bundle_id
    end

    apns_push_type = case push_type do
      :alert -> "alert"
      :voip -> "voip"
      :background -> "background"
      :complication -> "complication"
      _ -> "alert"
    end

    headers = [
      {"authorization", "bearer #{state.jwt_token}"},
      {"apns-topic", topic},
      {"apns-push-type", apns_push_type}
    ]

    # Add priority
    priority = case push_type do
      :voip -> "10"
      :alert -> "10"
      :background -> "5"
      _ -> "10"
    end
    headers = headers ++ [{"apns-priority", priority}]

    # Add expiration if specified
    if expiration = Keyword.get(opts, :expiration) do
      headers ++ [{"apns-expiration", to_string(expiration)}]
    else
      headers
    end
  end

  defp ensure_valid_token(%{jwt_token: nil} = state) do
    generate_jwt_token(state)
  end

  defp ensure_valid_token(%{token_generated_at: generated_at} = state) do
    # Check if token is older than 50 minutes
    if DateTime.diff(DateTime.utc_now(), generated_at, :second) > 3000 do
      generate_jwt_token(state)
    else
      state
    end
  end

  defp generate_jwt_token(%{private_key: nil} = state), do: state

  defp generate_jwt_token(state) do
    now = System.system_time(:second)

    claims = %{
      "iss" => state.team_id,
      "iat" => now
    }

    # Generate JWT token using ES256 algorithm
    token = case generate_es256_jwt(claims, state.key_id, state.private_key) do
      {:ok, jwt} -> jwt
      {:error, _} -> nil
    end

    %{state | jwt_token: token, token_generated_at: DateTime.utc_now()}
  end

  defp generate_es256_jwt(claims, key_id, private_key) do
    header = %{
      "alg" => "ES256",
      "kid" => key_id
    }

    header_b64 = Base.url_encode64(Jason.encode!(header), padding: false)
    claims_b64 = Base.url_encode64(Jason.encode!(claims), padding: false)
    signing_input = "#{header_b64}.#{claims_b64}"

    case sign_es256(signing_input, private_key) do
      {:ok, signature} ->
        signature_b64 = Base.url_encode64(signature, padding: false)
        {:ok, "#{signing_input}.#{signature_b64}"}

      error ->
        error
    end
  end

  defp sign_es256(data, private_key) do
    try do
      signature = :public_key.sign(data, :sha256, private_key)
      {:ok, signature}
    rescue
      e -> {:error, e}
    end
  end

  defp load_private_key(nil), do: nil
  defp load_private_key(path) do
    case File.read(path) do
      {:ok, pem} ->
        [entry] = :public_key.pem_decode(pem)
        :public_key.pem_entry_decode(entry)

      {:error, reason} ->
        Logger.error("Failed to load APNs private key: #{inspect(reason)}")
        nil
    end
  end

  defp schedule_token_refresh do
    Process.send_after(self(), :refresh_token, @token_refresh_interval)
  end
end
