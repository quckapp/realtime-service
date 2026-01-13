# QuckChat Realtime Server

High-performance real-time messaging server built with Elixir/Phoenix.

## Features

- **Real-time Messaging**: Phoenix Channels for instant message delivery
- **Voice/Video Calls**: WebRTC signaling for 1-on-1 calls
- **Huddles**: Persistent group audio/video rooms (like Discord/Slack)
- **Presence**: Real-time user online/offline tracking
- **Horizontal Scaling**: Redis PubSub for multi-node clustering
- **Push Notifications**: FCM/APNS for offline users

## Why Elixir/Phoenix?

The BEAM VM (Erlang) is specifically designed for:
- **Massive concurrency**: Handle millions of WebSocket connections
- **Low latency**: Sub-millisecond message delivery
- **Fault tolerance**: OTP supervision trees for reliability
- **Hot code upgrades**: Deploy without disconnecting users

WhatsApp uses Erlang for similar reasons.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Load Balancer (nginx)                     │
└──────────────────────────────┬──────────────────────────────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
        ▼                      ▼                      ▼
┌───────────────┐    ┌───────────────┐    ┌───────────────┐
│ Phoenix Node 1│    │ Phoenix Node 2│    │ Phoenix Node N│
│               │    │               │    │               │
│ - Chat Channel│    │ - Chat Channel│    │ - Chat Channel│
│ - WebRTC Chan │    │ - WebRTC Chan │    │ - WebRTC Chan │
│ - Huddle Chan │    │ - Huddle Chan │    │ - Huddle Chan │
└───────┬───────┘    └───────┬───────┘    └───────┬───────┘
        │                    │                    │
        └────────────────────┼────────────────────┘
                             │
                    ┌────────┴────────┐
                    │                 │
                    ▼                 ▼
            ┌─────────────┐   ┌─────────────┐
            │    Redis    │   │   MongoDB   │
            │   PubSub    │   │   (shared)  │
            └─────────────┘   └─────────────┘
```

## WebSocket Events

### Chat Channel (`chat:*`)

| Event | Direction | Description |
|-------|-----------|-------------|
| `message:send` | Client → Server | Send new message |
| `message:new` | Server → Client | New message received |
| `message:edit` | Client → Server | Edit message |
| `message:edited` | Server → Client | Message was edited |
| `message:delete` | Client → Server | Delete message |
| `message:deleted` | Server → Client | Message was deleted |
| `message:reaction:add` | Client → Server | Add emoji reaction |
| `message:reaction:added` | Server → Client | Reaction added |
| `message:reaction:remove` | Client → Server | Remove reaction |
| `message:reaction:removed` | Server → Client | Reaction removed |
| `typing:start` | Client → Server | User started typing |
| `typing:stop` | Client → Server | User stopped typing |
| `message:read` | Client → Server | Mark message as read |
| `user:online` | Server → Client | User came online |
| `user:offline` | Server → Client | User went offline |

### WebRTC Channel (`webrtc:*`)

| Event | Direction | Description |
|-------|-----------|-------------|
| `call:initiate` | Client → Server | Start a call |
| `call:incoming` | Server → Client | Incoming call |
| `call:answer` | Client → Server | Answer call |
| `call:answered` | Server → Client | Call was answered |
| `call:reject` | Client → Server | Reject call |
| `call:rejected` | Server → Client | Call was rejected |
| `call:end` | Client → Server | End call |
| `call:ended` | Server → Client | Call ended |
| `webrtc:offer` | Client → Server | Send WebRTC offer |
| `webrtc:answer` | Client → Server | Send WebRTC answer |
| `webrtc:ice-candidate` | Client → Server | Send ICE candidate |

### Huddle Channel (`huddle:*`)

| Event | Direction | Description |
|-------|-----------|-------------|
| `huddle:create` | Client → Server | Create huddle |
| `huddle:join` | - | Join huddle (topic subscription) |
| `huddle:leave` | Client → Server | Leave huddle |
| `huddle:participant:joined` | Server → Client | User joined |
| `huddle:participant:left` | Server → Client | User left |
| `huddle:toggle-audio` | Client → Server | Mute/unmute |
| `huddle:toggle-video` | Client → Server | Video on/off |
| `huddle:toggle-screen` | Client → Server | Screen share |
| `huddle:raise-hand` | Client → Server | Raise hand |

## Quick Start

### Development

```bash
# Install dependencies
mix deps.get

# Start server
mix phx.server

# Or with IEx
iex -S mix phx.server
```

### Docker

```bash
# Build and run
docker-compose up -d

# Scale multiple nodes
docker-compose --profile scaled up -d

# View logs
docker-compose logs -f realtime
```

### Production

```bash
# Build release
MIX_ENV=prod mix release

# Run
_build/prod/rel/quckchat_realtime/bin/quckchat_realtime start
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PORT` | HTTP port | 4000 |
| `HOST` | Hostname | localhost |
| `SECRET_KEY_BASE` | Phoenix secret key | Required |
| `JWT_SECRET` | JWT signing secret | Required |
| `MONGODB_URL` | MongoDB connection URL | mongodb://localhost:27017/quckchat |
| `REDIS_URL` | Redis connection URL | redis://localhost:6379 |
| `NODE_NAME` | Erlang node name | realtime@localhost |
| `BACKEND_URL` | NestJS backend URL | http://localhost:3000 |
| `STUN_SERVER_URL` | STUN server | stun:stun.l.google.com:19302 |
| `TURN_SERVER_URL` | TURN server (optional) | - |
| `TURN_USERNAME` | TURN username | - |
| `TURN_CREDENTIAL` | TURN credential | - |
| `FIREBASE_PROJECT_ID` | Firebase project | - |
| `FIREBASE_SERVICE_ACCOUNT` | Firebase service account JSON | - |

## Connecting from Client

```javascript
import { Socket } from "phoenix";

const socket = new Socket("ws://localhost:4000/socket", {
  params: { token: "your-jwt-token" }
});

socket.connect();

// Join chat channel
const chatChannel = socket.channel("chat:conversation-id", {});
chatChannel.join()
  .receive("ok", resp => console.log("Joined chat", resp))
  .receive("error", resp => console.log("Failed to join", resp));

// Send message
chatChannel.push("message:send", {
  conversationId: "conversation-id",
  type: "text",
  content: "Hello!"
});

// Listen for messages
chatChannel.on("message:new", message => {
  console.log("New message:", message);
});

// Join WebRTC channel for calls
const webrtcChannel = socket.channel("webrtc:lobby", {});
webrtcChannel.join();

// Listen for incoming calls
webrtcChannel.on("call:incoming", call => {
  console.log("Incoming call:", call);
});
```

## Monitoring

- Health check: `GET /health`
- Readiness: `GET /health/ready`
- Liveness: `GET /health/live`
- Prometheus metrics: `GET /metrics`
- Phoenix LiveDashboard (dev): `http://localhost:4000/dev/dashboard`

## Performance

Expected performance on a single node (8 vCPU, 16GB RAM):
- ~500,000 concurrent WebSocket connections
- ~50,000 messages/second
- <10ms average latency

## License

Private - AtomiverX
