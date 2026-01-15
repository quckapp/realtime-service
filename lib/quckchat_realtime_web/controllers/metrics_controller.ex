defmodule QuckAppRealtimeWeb.MetricsController do
  use QuckAppRealtimeWeb, :controller

  def index(conn, _params) do
    metrics = """
    # HELP quckapp_connected_users Number of connected users
    # TYPE quckapp_connected_users gauge
    quckapp_connected_users #{QuckAppRealtime.CallManager.connected_users_count()}

    # HELP quckapp_active_calls Number of active calls
    # TYPE quckapp_active_calls gauge
    quckapp_active_calls #{QuckAppRealtime.CallManager.active_calls_count()}

    # HELP quckapp_active_huddles Number of active huddles
    # TYPE quckapp_active_huddles gauge
    quckapp_active_huddles #{QuckAppRealtime.HuddleManager.active_huddles_count()}

    # HELP erlang_memory_bytes Erlang memory usage
    # TYPE erlang_memory_bytes gauge
    erlang_memory_bytes{type="total"} #{:erlang.memory(:total)}
    erlang_memory_bytes{type="processes"} #{:erlang.memory(:processes)}
    erlang_memory_bytes{type="binary"} #{:erlang.memory(:binary)}

    # HELP erlang_process_count Number of Erlang processes
    # TYPE erlang_process_count gauge
    erlang_process_count #{:erlang.system_info(:process_count)}
    """

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, metrics)
  end
end
