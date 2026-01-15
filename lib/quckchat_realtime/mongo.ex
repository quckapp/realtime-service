defmodule QuckAppRealtime.Mongo do
  @moduledoc """
  MongoDB Atlas Connection for QuckApp data.

  Hybrid Architecture:
  - MongoDB Atlas: Main data (users, conversations, messages, calls)
  - MySQL: Real-time queue only (store-and-forward for offline messages)

  This connects directly to MongoDB Atlas for:
  - User lookups
  - Conversation data
  - Call records
  - Session tracking
  """

  use GenServer
  require Logger

  @reconnect_interval 5_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    connect_to_mongodb()
  end

  defp connect_to_mongodb do
    config = Application.get_env(:quckapp_realtime, __MODULE__, [])
    url = Keyword.get(config, :url, "mongodb://localhost:27017/quckapp")
    pool_size = Keyword.get(config, :pool_size, 10)
    ssl = Keyword.get(config, :ssl, false)

    # MongoDB Atlas connection options
    opts = [
      url: url,
      pool_size: pool_size,
      name: :mongo_pool
    ]

    # Add SSL options for MongoDB Atlas
    opts = if ssl do
      Keyword.merge(opts, [
        ssl: true,
        ssl_opts: [
          verify: :verify_peer,
          cacertfile: CAStore.file_path(),
          server_name_indication: get_host_from_url(url),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      ])
    else
      opts
    end

    case Mongo.start_link(opts) do
      {:ok, _pid} ->
        Logger.info("MongoDB Atlas connected successfully")
        {:ok, %{connected: true}}

      {:error, reason} ->
        Logger.error("MongoDB Atlas connection failed: #{inspect(reason)}")
        Process.send_after(self(), :reconnect, @reconnect_interval)
        {:ok, %{connected: false}}
    end
  end

  defp get_host_from_url(url) do
    uri = URI.parse(url)
    String.to_charlist(uri.host || "localhost")
  end

  @impl true
  def handle_info(:reconnect, _state) do
    case connect_to_mongodb() do
      {:ok, new_state} -> {:noreply, new_state}
      _ -> {:noreply, %{connected: false}}
    end
  end

  # Public API

  def find_user(user_id) do
    case Mongo.find_one(:mongo_pool, "users", %{_id: BSON.ObjectId.decode!(user_id)}) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  rescue
    _ -> {:error, :invalid_id}
  end

  def find_users(user_ids) do
    object_ids =
      user_ids
      |> Enum.map(&BSON.ObjectId.decode!/1)
      |> Enum.reject(&is_nil/1)

    Mongo.find(:mongo_pool, "users", %{_id: %{"$in" => object_ids}})
    |> Enum.to_list()
  rescue
    _ -> []
  end

  def find_conversation(conversation_id) do
    case Mongo.find_one(:mongo_pool, "conversations", %{_id: BSON.ObjectId.decode!(conversation_id)}) do
      nil -> {:error, :not_found}
      conv -> {:ok, conv}
    end
  rescue
    _ -> {:error, :invalid_id}
  end

  def get_user_conversations(user_id) do
    Mongo.find(:mongo_pool, "conversations", %{
      "participants.userId" => BSON.ObjectId.decode!(user_id)
    })
    |> Enum.to_list()
  rescue
    _ -> []
  end

  def insert_message(message) do
    case Mongo.insert_one(:mongo_pool, "messages", message) do
      {:ok, result} -> {:ok, result.inserted_id}
      error -> error
    end
  end

  def update_message(message_id, updates) do
    Mongo.update_one(:mongo_pool, "messages", %{_id: BSON.ObjectId.decode!(message_id)}, %{"$set" => updates})
  rescue
    _ -> {:error, :invalid_id}
  end

  # ============================================
  # Call Records (MongoDB Atlas)
  # ============================================

  def insert_call(call) do
    call_doc = Map.merge(call, %{
      "createdAt" => DateTime.utc_now(),
      "updatedAt" => DateTime.utc_now()
    })

    case Mongo.insert_one(:mongo_pool, "calls", call_doc) do
      {:ok, result} -> {:ok, result.inserted_id}
      error -> error
    end
  end

  def update_call(call_id, updates) do
    updates_with_timestamp = Map.put(updates, "updatedAt", DateTime.utc_now())

    Mongo.update_one(
      :mongo_pool,
      "calls",
      %{callId: call_id},
      %{"$set" => updates_with_timestamp}
    )
  end

  def find_call(call_id) do
    case Mongo.find_one(:mongo_pool, "calls", %{callId: call_id}) do
      nil -> {:error, :not_found}
      call -> {:ok, call}
    end
  end

  def get_user_calls(user_id, limit \\ 50) do
    Mongo.find(:mongo_pool, "calls", %{
      "$or" => [
        %{"initiatorId" => user_id},
        %{"participants.userId" => user_id}
      ]
    }, sort: %{"createdAt" => -1}, limit: limit)
    |> Enum.to_list()
  end

  # ============================================
  # User Sessions (MongoDB Atlas)
  # ============================================

  def upsert_session(session) do
    session_doc = Map.merge(session, %{
      "updatedAt" => DateTime.utc_now()
    })

    Mongo.update_one(
      :mongo_pool,
      "user_sessions",
      %{userId: session.user_id, deviceId: session.device_id},
      %{
        "$set" => session_doc,
        "$setOnInsert" => %{"createdAt" => DateTime.utc_now()}
      },
      upsert: true
    )
  end

  def end_session(user_id, device_id) do
    Mongo.update_one(
      :mongo_pool,
      "user_sessions",
      %{userId: user_id, deviceId: device_id},
      %{
        "$set" => %{
          "isActive" => false,
          "disconnectedAt" => DateTime.utc_now(),
          "updatedAt" => DateTime.utc_now()
        }
      }
    )
  end

  def get_active_sessions(user_id) do
    Mongo.find(:mongo_pool, "user_sessions", %{
      userId: user_id,
      isActive: true
    })
    |> Enum.to_list()
  end

  def cleanup_stale_sessions(hours \\ 24) do
    cutoff = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    Mongo.update_many(
      :mongo_pool,
      "user_sessions",
      %{
        isActive: true,
        updatedAt: %{"$lt" => cutoff}
      },
      %{
        "$set" => %{
          isActive: false,
          disconnectedAt: DateTime.utc_now()
        }
      }
    )
  end

  # ============================================
  # Conversation Participants
  # ============================================

  def get_conversation_participants(conversation_id) do
    case find_conversation(conversation_id) do
      {:ok, conv} ->
        participants = conv["participants"] || []
        {:ok, Enum.map(participants, &(&1["userId"]))}

      error ->
        error
    end
  end
end
