defmodule QuckChatRealtimeWeb.Telemetry do
  @moduledoc """
  Telemetry metrics for monitoring the realtime server.
  """

  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),

      # Channel Metrics
      counter("phoenix.channel_joined.count",
        tags: [:channel]
      ),
      counter("phoenix.channel_handled_in.count",
        tags: [:channel, :event]
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:channel, :event],
        unit: {:native, :millisecond}
      ),

      # Socket Metrics
      counter("phoenix.socket_connected.count"),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),

      # Custom Metrics
      last_value("quckchat.connected_users.count"),
      last_value("quckchat.active_calls.count"),
      last_value("quckchat.active_huddles.count"),
      counter("quckchat.messages_sent.count"),
      counter("quckchat.calls_initiated.count"),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :measure_connected_users, []},
      {__MODULE__, :measure_active_calls, []},
      {__MODULE__, :measure_active_huddles, []}
    ]
  end

  def measure_connected_users do
    count = QuckChatRealtime.CallManager.connected_users_count()
    :telemetry.execute([:quckchat, :connected_users], %{count: count}, %{})
  end

  def measure_active_calls do
    count = QuckChatRealtime.CallManager.active_calls_count()
    :telemetry.execute([:quckchat, :active_calls], %{count: count}, %{})
  end

  def measure_active_huddles do
    count = QuckChatRealtime.HuddleManager.active_huddles_count()
    :telemetry.execute([:quckchat, :active_huddles], %{count: count}, %{})
  end
end
