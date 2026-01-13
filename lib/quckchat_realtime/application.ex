defmodule QuckChatRealtime.Application do
  @moduledoc """
  QuckChat Realtime Application - WhatsApp-Style Architecture.

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
      QuckChatRealtimeWeb.Telemetry,

      # ========================================
      # Core Infrastructure
      # ========================================

      # MySQL Repo for persistent storage
      QuckChatRealtime.Repo,

      # PubSub for distributed messaging
      {Phoenix.PubSub, name: QuckChatRealtime.PubSub},

      # Redis connection pool (for cross-node sync)
      QuckChatRealtime.Redis,

      # HTTP client for NestJS backend communication
      {Finch, name: QuckChatRealtime.Finch},

      # ========================================
      # WhatsApp-Style Components
      # ========================================

      # User process registry (for Actor lookup)
      {Registry, keys: :unique, name: QuckChatRealtime.UserRegistry},

      # Call session registry (for CallSession actors)
      {Registry, keys: :unique, name: QuckChatRealtime.CallRegistry},

      # Dynamic supervisor for user session actors
      QuckChatRealtime.ConnectionSupervisor,

      # Presence manager (ETS-based, O(1) lookups)
      QuckChatRealtime.PresenceManager,

      # Presence cleanup job (stale presence removal)
      QuckChatRealtime.PresenceCleanup,

      # Enhanced typing tracker with MapSet
      QuckChatRealtime.TypingTracker,

      # Store-and-Forward queue for offline messages
      QuckChatRealtime.StoreAndForward,

      # WebRTC signaling server with TURN credentials
      QuckChatRealtime.SignalingServer,

      # Call manager with state machine
      QuckChatRealtime.CallManagerV2,

      # Erlang cluster manager for distributed state
      QuckChatRealtime.ClusterManager,

      # Kafka event streaming
      QuckChatRealtime.Kafka.Producer,
      QuckChatRealtime.Kafka.Consumer,

      # ========================================
      # Notification Providers
      # ========================================

      # APNs provider for iOS push notifications
      QuckChatRealtime.Providers.APNs,

      # Email notification provider
      QuckChatRealtime.Providers.Email,

      # ========================================
      # Legacy Components (backward compatibility)
      # ========================================

      # Phoenix Presence (for Channel tracking)
      QuckChatRealtime.Presence,

      # Legacy call manager
      QuckChatRealtime.CallManager,

      # Huddle session manager
      QuckChatRealtime.HuddleManager,

      # Notification dispatcher (FCM + APNs + Email)
      QuckChatRealtime.NotificationDispatcher,

      # ========================================
      # Phoenix Endpoint (must be last)
      # ========================================
      QuckChatRealtimeWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: QuckChatRealtime.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    QuckChatRealtimeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
