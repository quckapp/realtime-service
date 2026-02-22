# Environment Configuration

This folder contains environment-specific configuration files for the Realtime Service.

## Available Environments

| File | Environment | Description |
|------|-------------|-------------|
| `dev.env` | Development | Local development with debug logging |
| `test.env` | Test | Automated testing with isolated databases |
| `staging.env` | Staging | Pre-production environment |
| `prod.env` | Production | Production environment with secrets from vault |
| `docker.env` | Docker | Docker Compose local development |

## Usage

### Local Development

```bash
cp envs/dev.env .env
mix phx.server
```

### Docker Development

```bash
docker-compose --env-file envs/docker.env up
```

## Service-Specific Variables

### WebSocket Configuration

- `WS_MAX_CONNECTIONS` - Maximum concurrent WebSocket connections
- `WS_HEARTBEAT_INTERVAL` - Heartbeat interval in milliseconds
- `WS_TIMEOUT` - Connection timeout in milliseconds

### WebRTC ICE Servers

- `STUN_SERVER_URL` - STUN server URL
- `TURN_SERVER_URL` - TURN server URL
- `TURN_USERNAME` - TURN username
- `TURN_CREDENTIAL` - TURN credential
