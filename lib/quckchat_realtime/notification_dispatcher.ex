defmodule QuckAppRealtime.NotificationDispatcher do
  @moduledoc """
  Handles dispatching push notifications for real-time events.

  Sends notifications via:
  - Firebase Cloud Messaging (FCM) for Android/Web
  - Apple Push Notification Service (APNS) for iOS

  Notification types:
  - New message (when user is offline)
  - Incoming call
  - Missed call
  - Huddle invitation
  - Mentions
  """

  use GenServer
  require Logger

  alias QuckAppRealtime.{Mongo, Redis, Presence}

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def dispatch_message_notification(conversation_id, sender_id, message) do
    GenServer.cast(__MODULE__, {:message_notification, conversation_id, sender_id, message})
  end

  def dispatch_call_notification(call_id, caller_id, participant_ids, call_type, conversation_id) do
    GenServer.cast(__MODULE__, {:call_notification, call_id, caller_id, participant_ids, call_type, conversation_id})
  end

  def dispatch_missed_call_notification(call_id, caller_id, receiver_ids) do
    GenServer.cast(__MODULE__, {:missed_call_notification, call_id, caller_id, receiver_ids})
  end

  def dispatch_huddle_invitation(huddle_id, inviter_id, invitee_ids, conversation_id) do
    GenServer.cast(__MODULE__, {:huddle_invitation, huddle_id, inviter_id, invitee_ids, conversation_id})
  end

  def dispatch_mention_notification(conversation_id, sender_id, mentioned_user_ids, message_id) do
    GenServer.cast(__MODULE__, {:mention_notification, conversation_id, sender_id, mentioned_user_ids, message_id})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:message_notification, conversation_id, sender_id, message}, state) do
    Task.start(fn ->
      send_message_notifications(conversation_id, sender_id, message)
    end)

    {:noreply, state}
  end

  def handle_cast({:call_notification, call_id, caller_id, participant_ids, call_type, conversation_id}, state) do
    Task.start(fn ->
      send_call_notifications(call_id, caller_id, participant_ids, call_type, conversation_id)
    end)

    {:noreply, state}
  end

  def handle_cast({:missed_call_notification, call_id, caller_id, receiver_ids}, state) do
    Task.start(fn ->
      send_missed_call_notifications(call_id, caller_id, receiver_ids)
    end)

    {:noreply, state}
  end

  def handle_cast({:huddle_invitation, huddle_id, inviter_id, invitee_ids, conversation_id}, state) do
    Task.start(fn ->
      send_huddle_invitations(huddle_id, inviter_id, invitee_ids, conversation_id)
    end)

    {:noreply, state}
  end

  def handle_cast({:mention_notification, conversation_id, sender_id, mentioned_user_ids, message_id}, state) do
    Task.start(fn ->
      send_mention_notifications(conversation_id, sender_id, mentioned_user_ids, message_id)
    end)

    {:noreply, state}
  end

  # Private functions

  defp send_message_notifications(conversation_id, sender_id, message) do
    case Mongo.find_conversation(conversation_id) do
      {:ok, conversation} ->
        participant_ids = get_participant_ids(conversation, exclude: sender_id)

        # Get offline users
        offline_users = Enum.reject(participant_ids, &Presence.is_online?/1)

        if length(offline_users) > 0 do
          users = Mongo.find_users(offline_users)
          sender = get_user_info(sender_id)

          fcm_tokens = users
            |> Enum.flat_map(&(Map.get(&1, "fcmTokens", [])))
            |> Enum.reject(&is_nil/1)

          if length(fcm_tokens) > 0 do
            {title, body} = format_message_notification(conversation, sender, message)

            send_fcm_notification(fcm_tokens, %{
              title: title,
              body: body,
              data: %{
                type: "message",
                conversation_id: conversation_id,
                message_id: message[:id]
              }
            })
          end
        end

      {:error, _} ->
        Logger.error("Conversation #{conversation_id} not found for notification")
    end
  end

  defp send_call_notifications(call_id, caller_id, participant_ids, call_type, conversation_id) do
    caller = get_user_info(caller_id)
    users = Mongo.find_users(participant_ids)

    for user <- users do
      fcm_tokens = Map.get(user, "fcmTokens", [])

      if length(fcm_tokens) > 0 do
        call_type_text = if call_type == "video", do: "Video", else: "Voice"

        send_fcm_notification(fcm_tokens, %{
          title: "Incoming #{call_type_text} Call",
          body: "#{caller["displayName"] || "Someone"} is calling you",
          data: %{
            type: "incoming_call",
            call_id: call_id,
            call_type: call_type,
            conversation_id: conversation_id,
            caller_id: caller_id,
            caller_name: caller["displayName"],
            caller_avatar: caller["avatar"]
          },
          android: %{
            priority: "high",
            ttl: "60s"
          },
          apns: %{
            headers: %{
              "apns-priority" => "10",
              "apns-push-type" => "voip"
            }
          }
        })
      end
    end
  end

  defp send_missed_call_notifications(call_id, caller_id, receiver_ids) do
    caller = get_user_info(caller_id)
    users = Mongo.find_users(receiver_ids)

    for user <- users do
      fcm_tokens = Map.get(user, "fcmTokens", [])

      if length(fcm_tokens) > 0 do
        send_fcm_notification(fcm_tokens, %{
          title: "Missed Call",
          body: "You missed a call from #{caller["displayName"] || "Someone"}",
          data: %{
            type: "missed_call",
            call_id: call_id,
            caller_id: caller_id
          }
        })
      end
    end
  end

  defp send_huddle_invitations(huddle_id, inviter_id, invitee_ids, conversation_id) do
    inviter = get_user_info(inviter_id)
    users = Mongo.find_users(invitee_ids)

    for user <- users do
      fcm_tokens = Map.get(user, "fcmTokens", [])

      if length(fcm_tokens) > 0 do
        send_fcm_notification(fcm_tokens, %{
          title: "Huddle Invitation",
          body: "#{inviter["displayName"] || "Someone"} invited you to join a huddle",
          data: %{
            type: "huddle_invitation",
            huddle_id: huddle_id,
            conversation_id: conversation_id,
            inviter_id: inviter_id
          }
        })
      end
    end
  end

  defp send_mention_notifications(conversation_id, sender_id, mentioned_user_ids, message_id) do
    sender = get_user_info(sender_id)
    offline_users = Enum.reject(mentioned_user_ids, &Presence.is_online?/1)

    if length(offline_users) > 0 do
      users = Mongo.find_users(offline_users)

      for user <- users do
        fcm_tokens = Map.get(user, "fcmTokens", [])

        if length(fcm_tokens) > 0 do
          send_fcm_notification(fcm_tokens, %{
            title: "You were mentioned",
            body: "#{sender["displayName"] || "Someone"} mentioned you in a message",
            data: %{
              type: "mention",
              conversation_id: conversation_id,
              message_id: message_id,
              sender_id: sender_id
            }
          })
        end
      end
    end
  end

  defp send_fcm_notification(tokens, payload) do
    # In production, implement actual FCM sending
    # Using Firebase Admin SDK via HTTP API
    config = Application.get_env(:quckapp_realtime, :firebase, [])
    project_id = Keyword.get(config, :project_id)

    if project_id do
      url = "https://fcm.googleapis.com/v1/projects/#{project_id}/messages:send"

      for token <- tokens do
        message = %{
          message: %{
            token: token,
            notification: %{
              title: payload[:title],
              body: payload[:body]
            },
            data: stringify_data(payload[:data]),
            android: payload[:android],
            apns: payload[:apns]
          }
        }

        case send_http_request(url, message) do
          {:ok, _} ->
            Logger.debug("FCM notification sent to #{String.slice(token, 0..10)}...")

          {:error, reason} ->
            Logger.error("FCM notification failed: #{inspect(reason)}")
        end
      end
    else
      Logger.debug("FCM not configured, skipping notification: #{inspect(payload[:title])}")
    end
  end

  defp send_http_request(url, body) do
    # Use Finch or Req for HTTP requests
    # This is a placeholder - implement with actual HTTP client
    Logger.debug("Would send to #{url}: #{inspect(body)}")
    {:ok, %{}}
  end

  defp get_participant_ids(conversation, opts) do
    exclude = Keyword.get(opts, :exclude)

    conversation
    |> Map.get("participants", [])
    |> Enum.map(&Map.get(&1, "userId"))
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == exclude))
  end

  defp get_user_info(user_id) do
    case Mongo.find_user(user_id) do
      {:ok, user} -> user
      _ -> %{"displayName" => "Unknown"}
    end
  end

  defp format_message_notification(conversation, sender, message) do
    sender_name = sender["displayName"] || "Someone"

    case conversation["type"] do
      "group" ->
        conv_name = conversation["name"] || "Group"
        body = case message[:type] do
          "text" -> message[:content] || "Sent a message"
          "image" -> "Sent an image"
          "video" -> "Sent a video"
          "audio" -> "Sent a voice message"
          "file" -> "Sent a file"
          _ -> "Sent a message"
        end

        {conv_name, "#{sender_name}: #{body}"}

      _ ->
        body = case message[:type] do
          "text" -> message[:content] || "Sent you a message"
          "image" -> "Sent you an image"
          "video" -> "Sent you a video"
          "audio" -> "Sent you a voice message"
          "file" -> "Sent you a file"
          _ -> "Sent you a message"
        end

        {sender_name, body}
    end
  end

  defp stringify_data(nil), do: %{}
  defp stringify_data(data) when is_map(data) do
    data
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
    |> Map.new()
  end
end
