defmodule QuckAppRealtime.ParallelRouter do
  @moduledoc """
  Flow-based parallel message router for high-throughput message delivery.

  Uses Elixir Flow library for parallel processing of messages to multiple recipients.
  This is particularly useful for group messages where we need to fan out to 100+ recipients.

  ## Usage:

      # Parallel delivery to multiple recipients
      ParallelRouter.deliver_to_many(message, recipient_ids)

      # Parallel event broadcast
      ParallelRouter.broadcast_event(event, recipient_ids)

  ## Configuration:

  Configure in config.exs:

      config :quckapp_realtime, :parallel_router,
        max_demand: 100,           # Max items per stage
        stages: System.schedulers_online()  # Number of parallel stages
  """

  require Logger

  alias QuckAppRealtime.Actors.UserSession

  @doc """
  Deliver a message to multiple recipients in parallel.

  Returns a summary of delivery results.
  """
  def deliver_to_many(message, recipient_ids, opts \\ []) when is_list(recipient_ids) do
    sender_id = message.sender_id

    # Filter out sender from recipients
    recipients = Enum.reject(recipient_ids, &(&1 == sender_id))

    case length(recipients) do
      0 ->
        {:ok, %{delivered: 0, queued: 0, failed: 0}}

      count when count <= 10 ->
        # For small recipient lists, use simple Enum
        deliver_sequential(message, recipients, opts)

      _ ->
        # For larger lists, use Flow for parallel processing
        deliver_parallel(message, recipients, opts)
    end
  end

  @doc """
  Broadcast an event to multiple recipients in parallel.
  Events are real-time only (not persisted/queued).
  """
  def broadcast_event(event, recipient_ids, opts \\ []) when is_list(recipient_ids) do
    case length(recipient_ids) do
      0 ->
        {:ok, %{delivered: 0}}

      count when count <= 10 ->
        # For small lists, use simple Enum
        delivered = Enum.count(recipient_ids, fn id ->
          deliver_event(id, event, opts)
        end)
        {:ok, %{delivered: delivered}}

      _ ->
        # For larger lists, use Flow
        broadcast_parallel(event, recipient_ids, opts)
    end
  end

  @doc """
  Fan out a call signal to multiple participants in parallel.
  """
  def broadcast_call_signal(signal, participant_ids) when is_list(participant_ids) do
    results =
      participant_ids
      |> Flow.from_enumerable(max_demand: max_demand(), stages: stages())
      |> Flow.map(fn user_id ->
        if UserSession.online?(user_id) do
          UserSession.send_message(user_id, signal)
          {:delivered, user_id}
        else
          {:offline, user_id}
        end
      end)
      |> Enum.to_list()

    delivered = Enum.count(results, fn {status, _} -> status == :delivered end)
    offline = Enum.count(results, fn {status, _} -> status == :offline end)

    {:ok, %{delivered: delivered, offline: offline}}
  end

  # Private functions

  defp deliver_sequential(message, recipients, _opts) do
    results = Enum.map(recipients, fn recipient_id ->
      deliver_to_recipient(message, recipient_id)
    end)

    delivered = Enum.count(results, &(&1 == :delivered))
    queued = Enum.count(results, &(&1 == :queued))
    failed = Enum.count(results, &(&1 == :failed))

    {:ok, %{delivered: delivered, queued: queued, failed: failed}}
  end

  defp deliver_parallel(message, recipients, _opts) do
    results =
      recipients
      |> Flow.from_enumerable(max_demand: max_demand(), stages: stages())
      |> Flow.map(fn recipient_id ->
        deliver_to_recipient(message, recipient_id)
      end)
      |> Enum.to_list()

    delivered = Enum.count(results, &(&1 == :delivered))
    queued = Enum.count(results, &(&1 == :queued))
    failed = Enum.count(results, &(&1 == :failed))

    Logger.debug("[ParallelRouter] Delivered to #{delivered}, queued #{queued}, failed #{failed} of #{length(recipients)}")

    {:ok, %{delivered: delivered, queued: queued, failed: failed}}
  end

  defp deliver_to_recipient(message, recipient_id) do
    try do
      if UserSession.online?(recipient_id) do
        UserSession.send_message(recipient_id, format_message(message))
        :delivered
      else
        queue_for_offline(message, recipient_id)
        :queued
      end
    rescue
      e ->
        Logger.error("[ParallelRouter] Failed to deliver to #{recipient_id}: #{inspect(e)}")
        :failed
    end
  end

  defp deliver_event(recipient_id, event, _opts) do
    if UserSession.online?(recipient_id) do
      UserSession.send_message(recipient_id, event)
      true
    else
      false
    end
  end

  defp broadcast_parallel(event, recipient_ids, _opts) do
    delivered =
      recipient_ids
      |> Flow.from_enumerable(max_demand: max_demand(), stages: stages())
      |> Flow.filter(fn user_id ->
        if UserSession.online?(user_id) do
          UserSession.send_message(user_id, event)
          true
        else
          false
        end
      end)
      |> Enum.count()

    {:ok, %{delivered: delivered}}
  end

  defp format_message(message) do
    %{
      type: "message:new",
      data: %{
        id: message[:id],
        conversation_id: message.conversation_id,
        sender_id: message.sender_id,
        type: message[:type] || "text",
        content: message[:content],
        metadata: message[:metadata] || %{},
        timestamp: message[:timestamp] || DateTime.utc_now()
      }
    }
  end

  defp queue_for_offline(message, recipient_id) do
    QuckAppRealtime.StoreAndForward.queue_message(%{
      message_id: message[:id] || message["id"],
      conversation_id: message.conversation_id,
      sender_id: message.sender_id,
      recipient_id: recipient_id,
      message_type: message[:type] || "text",
      content: message[:content],
      metadata: message[:metadata] || %{},
      priority: get_priority(message)
    })
  end

  defp get_priority(message) do
    case message[:type] do
      "call" -> 10
      "system" -> 5
      _ -> 0
    end
  end

  defp max_demand do
    config()[:max_demand] || 100
  end

  defp stages do
    config()[:stages] || System.schedulers_online()
  end

  defp config do
    Application.get_env(:quckapp_realtime, :parallel_router, [])
  end
end
