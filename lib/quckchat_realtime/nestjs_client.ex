defmodule QuckAppRealtime.NestJSClient do
  @moduledoc """
  HTTP Client for communicating with NestJS backend.

  This module provides functions to call NestJS microservices:
  - Users Service: Get user info, presence, FCM tokens
  - Messages Service: Persist messages, mark as read
  - Conversations Service: Get conversations, participants
  - Calls Service: Persist call history
  - Notifications Service: Send push notifications

  All calls use the internal API endpoints with service-to-service authentication.
  """

  require Logger

  @default_timeout 10_000

  # ============================================
  # Users Service
  # ============================================

  @doc """
  Get user by ID
  """
  def get_user(user_id) do
    get("/internal/users/#{user_id}")
  end

  @doc """
  Get multiple users by IDs
  """
  def get_users(user_ids) when is_list(user_ids) do
    post("/internal/users/batch", %{userIds: user_ids})
  end

  @doc """
  Get user's FCM tokens for push notifications
  """
  def get_user_fcm_tokens(user_id) do
    get("/internal/users/#{user_id}/fcm-tokens")
  end

  @doc """
  Update user presence status
  """
  def update_user_presence(user_id, status) do
    put("/internal/users/#{user_id}/presence", %{status: status})
  end

  # ============================================
  # Conversations Service
  # ============================================

  @doc """
  Get conversation by ID
  """
  def get_conversation(conversation_id) do
    get("/internal/conversations/#{conversation_id}")
  end

  @doc """
  Get user's conversations
  """
  def get_user_conversations(user_id) do
    get("/internal/conversations/user/#{user_id}")
  end

  @doc """
  Get conversation participants
  """
  def get_conversation_participants(conversation_id) do
    get("/internal/conversations/#{conversation_id}/participants")
  end

  @doc """
  Increment unread count for users
  """
  def increment_unread_count(conversation_id, user_ids) do
    post("/internal/conversations/#{conversation_id}/unread/increment", %{userIds: user_ids})
  end

  @doc """
  Clear unread count for user
  """
  def clear_unread_count(conversation_id, user_id, last_read_message_id) do
    post("/internal/conversations/#{conversation_id}/unread/clear", %{
      userId: user_id,
      lastReadMessageId: last_read_message_id
    })
  end

  # ============================================
  # Messages Service
  # ============================================

  @doc """
  Create a new message
  """
  def create_message(conversation_id, sender_id, type, content, opts \\ %{}) do
    post("/internal/messages", Map.merge(%{
      conversationId: conversation_id,
      senderId: sender_id,
      type: type,
      content: content
    }, opts))
  end

  @doc """
  Get message by ID
  """
  def get_message(message_id) do
    get("/internal/messages/#{message_id}")
  end

  @doc """
  Update message (edit)
  """
  def update_message(message_id, user_id, content) do
    put("/internal/messages/#{message_id}", %{userId: user_id, content: content})
  end

  @doc """
  Delete message
  """
  def delete_message(message_id, user_id) do
    delete("/internal/messages/#{message_id}", %{userId: user_id})
  end

  @doc """
  Add reaction to message
  """
  def add_reaction(message_id, user_id, emoji) do
    post("/internal/messages/#{message_id}/reactions", %{userId: user_id, emoji: emoji})
  end

  @doc """
  Remove reaction from message
  """
  def remove_reaction(message_id, user_id, emoji) do
    delete("/internal/messages/#{message_id}/reactions", %{userId: user_id, emoji: emoji})
  end

  @doc """
  Mark message as delivered
  """
  def mark_delivered(message_id, user_id) do
    post("/internal/messages/#{message_id}/delivered", %{userId: user_id})
  end

  @doc """
  Mark message as read
  """
  def mark_read(message_id, user_id) do
    post("/internal/messages/#{message_id}/read", %{userId: user_id})
  end

  # ============================================
  # Calls Service
  # ============================================

  @doc """
  Create a new call record
  """
  def create_call(initiator_id, conversation_id, participant_ids, type) do
    post("/internal/calls", %{
      initiatorId: initiator_id,
      conversationId: conversation_id,
      participantIds: participant_ids,
      type: type
    })
  end

  @doc """
  Update call status
  """
  def update_call(call_id, updates) do
    put("/internal/calls/#{call_id}", updates)
  end

  @doc """
  Record participant joining call
  """
  def join_call(call_id, user_id) do
    post("/internal/calls/#{call_id}/join", %{userId: user_id})
  end

  @doc """
  End a call
  """
  def end_call(call_id, ended_by, duration, reason) do
    post("/internal/calls/#{call_id}/end", %{
      endedBy: ended_by,
      duration: duration,
      endReason: reason
    })
  end

  # ============================================
  # Notifications Service
  # ============================================

  @doc """
  Send push notification to users
  """
  def send_push_notification(user_ids, title, body, data \\ %{}) do
    post("/internal/notifications/push", %{
      userIds: user_ids,
      title: title,
      body: body,
      data: data
    })
  end

  @doc """
  Send call notification (high priority)
  """
  def send_call_notification(user_ids, caller_name, call_type, call_id, conversation_id) do
    post("/internal/notifications/call", %{
      userIds: user_ids,
      callerName: caller_name,
      callType: call_type,
      callId: call_id,
      conversationId: conversation_id
    })
  end

  # ============================================
  # HTTP Helpers
  # ============================================

  defp get(path) do
    request(:get, path)
  end

  defp post(path, body) do
    request(:post, path, body)
  end

  defp put(path, body) do
    request(:put, path, body)
  end

  defp delete(path, body \\ nil) do
    request(:delete, path, body)
  end

  defp request(method, path, body \\ nil) do
    base_url = get_base_url()
    url = base_url <> path
    headers = get_headers()

    opts = [
      headers: headers,
      receive_timeout: @default_timeout
    ]

    opts = if body, do: Keyword.put(opts, :json, body), else: opts

    result = case method do
      :get -> Req.get(url, opts)
      :post -> Req.post(url, opts)
      :put -> Req.put(url, opts)
      :delete -> Req.delete(url, opts)
    end

    handle_response(result, path)
  end

  defp handle_response({:ok, %Req.Response{status: code, body: body}}, _path) when code in 200..299 do
    {:ok, body}
  end

  defp handle_response({:ok, %Req.Response{status: code, body: body}}, path) do
    Logger.error("NestJS API error: #{path} returned #{code}: #{inspect(body)}")
    {:error, %{status: code, error: body}}
  end

  defp handle_response({:error, exception}, path) do
    Logger.error("NestJS API connection error: #{path} - #{inspect(exception)}")
    {:error, %{status: 0, error: %{"message" => "Connection error: #{inspect(exception)}"}}}
  end

  defp get_base_url do
    Application.get_env(:quckapp_realtime, :nestjs_url, "http://localhost:3000")
  end

  defp get_headers do
    api_key = Application.get_env(:quckapp_realtime, :nestjs_api_key)

    base_headers = [
      {"Content-Type", "application/json"},
      {"Accept", "application/json"},
      {"X-Service-Name", "realtime-service"}
    ]

    if api_key do
      [{"X-API-Key", api_key} | base_headers]
    else
      base_headers
    end
  end
end
