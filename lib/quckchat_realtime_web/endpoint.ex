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
