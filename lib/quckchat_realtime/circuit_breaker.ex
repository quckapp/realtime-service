defmodule QuckAppRealtime.CircuitBreaker do
  @moduledoc """
  Circuit breaker wrapper using the fuse library.

  Provides fault tolerance for external service calls (Redis, MongoDB, HTTP, Kafka, NestJS).
  When a service fails repeatedly, the circuit opens and fails fast,
  preventing cascade failures and allowing the service to recover.

  ## Critical Protection:
  The NestJS client has no protection currently - this module adds critical
  circuit breaker protection for all external HTTP calls.

  ## Usage:

      CircuitBreaker.call(:nestjs, fn ->
        NestJSClient.get_user(user_id)
      end)

      CircuitBreaker.call(:redis, fn ->
        Redix.command(:redix, ["GET", key])
      end, default: nil)
  """

  require Logger

  @fuses %{
    redis: :realtime_redis_fuse,
    mongodb: :realtime_mongodb_fuse,
    nestjs: :realtime_nestjs_fuse,
    kafka: :realtime_kafka_fuse,
    http: :realtime_http_fuse
  }

  @doc """
  Initialize all circuit breakers. Call this from Application.start/2.
  """
  def init do
    Enum.each(@fuses, fn {name, fuse_name} ->
      opts = fuse_options(name)
      :fuse.install(fuse_name, opts)
      Logger.info("[CircuitBreaker] Installed fuse #{fuse_name}")
    end)
    :ok
  end

  @doc """
  Execute a function with circuit breaker protection.
  """
  def call(service, fun, opts \\ []) do
    fuse_name = Map.get(@fuses, service, service)

    case :fuse.ask(fuse_name, :sync) do
      :ok ->
        try do
          result = fun.()
          handle_result(fuse_name, result)
        rescue
          e ->
            :fuse.melt(fuse_name)
            Logger.error("[CircuitBreaker] #{service} call failed: #{inspect(e)}")
            handle_error(service, opts, e)
        catch
          :exit, reason ->
            :fuse.melt(fuse_name)
            Logger.error("[CircuitBreaker] #{service} call exited: #{inspect(reason)}")
            handle_error(service, opts, reason)
        end

      :blown ->
        Logger.warning("[CircuitBreaker] #{service} circuit is open, failing fast")
        emit_circuit_open_telemetry(service)
        if on_open = opts[:on_open], do: on_open.()
        Keyword.get(opts, :default, {:error, :circuit_open})

      {:error, :not_found} ->
        Logger.warning("[CircuitBreaker] Fuse #{service} not installed, running unprotected")
        fun.()
    end
  end

  @doc """
  Wrap an HTTP request with circuit breaker protection.
  Automatically detects errors from Req responses.
  """
  def http_call(service, fun, opts \\ []) do
    call(service, fn ->
      case fun.() do
        {:ok, %{status: status}} when status >= 500 ->
          {:error, {:http_error, status}}

        {:ok, _} = result ->
          result

        {:error, _} = error ->
          error
      end
    end, opts)
  end

  @doc """
  Run a function only if the circuit is closed.
  """
  def run_if_closed(service, fun, opts \\ []) do
    fuse_name = Map.get(@fuses, service, service)

    case :fuse.ask(fuse_name, :sync) do
      :ok -> fun.()
      :blown -> Keyword.get(opts, :default, {:error, :circuit_open})
      {:error, :not_found} -> fun.()
    end
  end

  @doc """
  Record a successful call.
  """
  def success(service) do
    fuse_name = Map.get(@fuses, service, service)
    :fuse.reset(fuse_name)
  end

  @doc """
  Record a failed call.
  """
  def failure(service) do
    fuse_name = Map.get(@fuses, service, service)
    :fuse.melt(fuse_name)
  end

  @doc """
  Check if a circuit is currently open.
  """
  def open?(service) do
    fuse_name = Map.get(@fuses, service, service)
    :fuse.ask(fuse_name, :sync) == :blown
  end

  @doc """
  Manually reset a circuit.
  """
  def reset(service) do
    fuse_name = Map.get(@fuses, service, service)
    :fuse.reset(fuse_name)
  end

  @doc """
  Get the current status of all circuits.
  """
  def status do
    Enum.map(@fuses, fn {name, fuse_name} ->
      state = case :fuse.ask(fuse_name, :sync) do
        :ok -> :closed
        :blown -> :open
        {:error, :not_found} -> :not_installed
      end
      {name, state}
    end)
    |> Map.new()
  end

  # Private functions

  defp handle_result(fuse_name, {:ok, _} = result) do
    result
  end

  defp handle_result(fuse_name, {:error, reason} = result) do
    :fuse.melt(fuse_name)
    result
  end

  defp handle_result(_fuse_name, result) do
    result
  end

  defp fuse_options(service) do
    config = Application.get_env(:quckapp_realtime, :circuit_breaker, %{})
    service_config = Map.get(config, service, %{})

    # NestJS gets stricter settings as it's critical
    defaults = case service do
      :nestjs -> %{max_failures: 3, time_window: 10_000, reset_timeout: 60_000}
      _ -> %{max_failures: 5, time_window: 10_000, reset_timeout: 30_000}
    end

    max_failures = Map.get(service_config, :max_failures, defaults.max_failures)
    time_window = Map.get(service_config, :time_window, defaults.time_window)
    reset_timeout = Map.get(service_config, :reset_timeout, defaults.reset_timeout)

    {{:standard, max_failures, time_window}, {:reset, reset_timeout}}
  end

  defp handle_error(_service, opts, error) do
    case Keyword.get(opts, :default) do
      nil -> {:error, {:circuit_breaker_error, error}}
      default -> default
    end
  end

  defp emit_circuit_open_telemetry(service) do
    :telemetry.execute(
      [:quckapp_realtime, :circuit_breaker, :open],
      %{count: 1},
      %{service: service}
    )
  end
end
