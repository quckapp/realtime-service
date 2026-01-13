defmodule QuckChatRealtimeWeb.MetricsController do
  use QuckChatRealtimeWeb, :controller

  def index(conn, _params) do
    metrics = """
    # HELP quckchat_connected_users Number of connected users
    # TYPE quckchat_connected_users gauge
    quckchat_connected_users #{QuckChatRealtime.CallManager.connected_users_count()}

    # HELP quckchat_active_calls Number of active calls
    # TYPE quckchat_active_calls gauge
    quckchat_active_calls #{QuckChatRealtime.CallManager.active_calls_count()}

    # HELP quckchat_active_huddles Number of active huddles
    # TYPE quckchat_active_huddles gauge
    quckchat_active_huddles #{QuckChatRealtime.HuddleManager.active_huddles_count()}

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
