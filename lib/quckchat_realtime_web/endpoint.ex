defmodule QuckAppRealtimeWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :quckapp_realtime

  # Socket for real-time communication
  socket "/socket", QuckAppRealtimeWeb.UserSocket,
    websocket: [
      timeout: 45_000,
      compress: true,
      max_frame_size: 1_000_000
    ],
    longpoll: false

  # LiveDashboard in development
  if Application.compile_env(:quckapp_realtime, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]
      live_dashboard "/dashboard",
        metrics: QuckAppRealtimeWeb.Telemetry,
        ecto_repos: []
    end
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head

  plug CORSPlug,
    origin: ["*"],
    methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    headers: ["Authorization", "Content-Type", "Accept"]

  plug QuckAppRealtimeWeb.Router
end
