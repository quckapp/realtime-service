defmodule QuckAppRealtime.Application do
  @moduledoc """
  QuckApp Realtime Application - WhatsApp-Style Architecture.

  Handles:
  - Real-time messaging (Phoenix Channels + Actor Model)
  - WebRTC signaling for voice/video calls
  - Huddle (group audio/video rooms)
  - User presence tracking (ETS + Redis)
  - Store-and-Forward for offline messages (MySQL)
  - Erlang clustering for horizontal scaling
  - Push notifications (FCM/APNs/Email)
  - Call recording management

  Architecture:
  - One GenServer per connected user (Actor Model)
  - ETS for O(1) presence lookups
  - MySQL for persistent message queue
  - Redis for cross-node state sync
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Telemetry supervisor
      QuckAppRealtimeWeb.Telemetry,

      # ========================================
      # Core Infrastructure
      # ========================================

      # MySQL Repo for persistent storage
      QuckAppRealtime.Repo,

      # PubSub for distributed messaging
      {Phoenix.PubSub, name: QuckAppRealtime.PubSub},

      # Redis connection pool (for cross-node sync)
      QuckAppRealtime.Redis,

      # HTTP client for NestJS backend communication
      {Finch, name: QuckAppRealtime.Finch},

      # ========================================
      # WhatsApp-Style Components
      # ========================================

      # User process registry (for Actor lookup)
      {Registry, keys: :unique, name: QuckAppRealtime.UserRegistry},

      # Call session registry (for CallSession actors)
      {Registry, keys: :unique, name: QuckAppRealtime.CallRegistry},

      # Dynamic supervisor for user session actors
      QuckAppRealtime.ConnectionSupervisor,

      # Presence manager (ETS-based, O(1) lookups)
      QuckAppRealtime.PresenceManager,

      # Presence cleanup job (stale presence removal)
      QuckAppRealtime.PresenceCleanup,

      # Enhanced typing tracker with MapSet
      QuckAppRealtime.TypingTracker,

      # Store-and-Forward queue for offline messages
      QuckAppRealtime.StoreAndForward,

      # WebRTC signaling server with TURN credentials
      QuckAppRealtime.SignalingServer,

      # Call manager with state machine
      QuckAppRealtime.CallManagerV2,

      # Erlang cluster manager for distributed state
      QuckAppRealtime.ClusterManager,

      # Kafka event streaming
      QuckAppRealtime.Kafka.Producer,
      QuckAppRealtime.Kafka.Consumer,

      # ========================================
      # Notification Providers
      # ========================================

      # APNs provider for iOS push notifications
      QuckAppRealtime.Providers.APNs,

      # Email notification provider
      QuckAppRealtime.Providers.Email,

      # ========================================
      # Legacy Components (backward compatibility)
      # ========================================

      # Phoenix Presence (for Channel tracking)
      QuckAppRealtime.Presence,

      # Legacy call manager
      QuckAppRealtime.CallManager,

      # Huddle session manager
      QuckAppRealtime.HuddleManager,

      # Notification dispatcher (FCM + APNs + Email)
      QuckAppRealtime.NotificationDispatcher,

      # ========================================
      # Phoenix Endpoint (must be last)
      # ========================================
      QuckAppRealtimeWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: QuckAppRealtime.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    QuckAppRealtimeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
