defmodule QuckChatRealtimeWeb.Router do
  use QuckChatRealtimeWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated do
    plug :accepts, ["json"]
    # Add authentication plug here
    # plug QuckChatRealtimeWeb.Plugs.AuthPlug
  end

  # Health check endpoints
  scope "/", QuckChatRealtimeWeb do
    pipe_through :api

    get "/health", HealthController, :index
    get "/health/ready", HealthController, :ready
    get "/health/live", HealthController, :live
  end

  # Metrics endpoint (for Prometheus)
  scope "/metrics", QuckChatRealtimeWeb do
    pipe_through :api

    get "/", MetricsController, :index
  end

  # API endpoints for managing state
  scope "/api", QuckChatRealtimeWeb do
    pipe_through :api

    # Call management
    post "/calls/:call_id/invite", CallController, :invite
    get "/calls/:call_id/participants", CallController, :participants
    get "/calls/:call_id/ice-servers", CallController, :ice_servers

    # Call recording
    post "/calls/:call_id/recording/start", RecordingController, :start
    post "/calls/:call_id/recording/stop", RecordingController, :stop
    get "/calls/:call_id/recording/status", RecordingController, :status

    # Recording management
    get "/recordings", RecordingController, :list
    get "/recordings/:recording_id", RecordingController, :show
    delete "/recordings/:recording_id", RecordingController, :delete
    get "/recordings/:recording_id/download", RecordingController, :download_url

    # Huddle management
    post "/huddles", HuddleController, :create
    get "/huddles/:huddle_id", HuddleController, :show
    post "/huddles/:huddle_id/invite", HuddleController, :invite
    post "/huddles/:huddle_id/join", HuddleController, :join
    post "/huddles/:huddle_id/leave", HuddleController, :leave

    # Presence
    get "/presence/:user_id", PresenceController, :show
    get "/presence/online", PresenceController, :online_users
    get "/presence/typing/:conversation_id", PresenceController, :typing_users

    # Device management (push notification tokens)
    post "/devices", DeviceController, :register
    get "/devices", DeviceController, :list
    put "/devices/:device_id/token", DeviceController, :update_token
    delete "/devices/:device_id", DeviceController, :unregister
    post "/devices/:device_id/heartbeat", DeviceController, :heartbeat

    # Signaling (WebRTC)
    get "/signaling/ice-config", SignalingController, :ice_config
    post "/signaling/turn-credentials", SignalingController, :turn_credentials
  end
end
