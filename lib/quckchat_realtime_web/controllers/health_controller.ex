defmodule QuckAppRealtimeWeb.HealthController do
  use QuckAppRealtimeWeb, :controller

  alias QuckAppRealtime.{CallManager, HuddleManager, Redis}

  def index(conn, _params) do
    json(conn, %{
      status: "ok",
      service: "quckapp-realtime",
      version: "1.0.0",
      timestamp: DateTime.utc_now()
    })
  end

  def ready(conn, _params) do
    checks = %{
      redis: check_redis(),
      mongodb: check_mongodb()
    }

    all_ok = Enum.all?(checks, fn {_, status} -> status == :ok end)

    status_code = if all_ok, do: 200, else: 503

    conn
    |> put_status(status_code)
    |> json(%{
      ready: all_ok,
      checks: Map.new(checks, fn {k, v} -> {k, v == :ok} end)
    })
  end

  def live(conn, _params) do
    stats = %{
      connected_users: CallManager.connected_users_count(),
      active_calls: CallManager.active_calls_count(),
      active_huddles: HuddleManager.active_huddles_count(),
      memory_mb: :erlang.memory(:total) / 1_000_000 |> Float.round(2),
      uptime_seconds: :erlang.statistics(:wall_clock) |> elem(0) |> div(1000)
    }

    json(conn, %{
      alive: true,
      stats: stats
    })
  end

  defp check_redis do
    case Redis.command(["PING"]) do
      {:ok, "PONG"} -> :ok
      _ -> :error
    end
  end

  defp check_mongodb do
    # Simple ping check
    try do
      case Mongo.command(:mongo_pool, %{ping: 1}) do
        {:ok, _} -> :ok
        _ -> :error
      end
    rescue
      _ -> :error
    end
  end
end
