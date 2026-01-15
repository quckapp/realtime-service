defmodule QuckAppRealtime.Schemas.PendingMessage do
  @moduledoc """
  Schema for Store-and-Forward message queue.

  Messages are stored here when the recipient is offline.
  Once delivered, they are deleted from this table.

  WhatsApp-style: Messages are queued and delivered when user comes online.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "pending_messages" do
    field :message_id, :string           # Original message ID from MongoDB
    field :conversation_id, :string
    field :sender_id, :string
    field :recipient_id, :string         # User who should receive this
    field :message_type, :string         # text, image, video, audio, file
    field :content, :string              # Encrypted content
    field :metadata, :map, default: %{}  # Attachments, reply_to, etc.
    field :priority, :integer, default: 0 # Higher = more urgent
    field :retry_count, :integer, default: 0
    field :max_retries, :integer, default: 3
    field :expires_at, :utc_datetime_usec # TTL for message

    timestamps()
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :message_id, :conversation_id, :sender_id, :recipient_id,
      :message_type, :content, :metadata, :priority, :retry_count,
      :max_retries, :expires_at
    ])
    |> validate_required([:message_id, :conversation_id, :sender_id, :recipient_id, :message_type])
    |> validate_inclusion(:message_type, ["text", "image", "video", "audio", "file", "call", "system"])
  end
end
