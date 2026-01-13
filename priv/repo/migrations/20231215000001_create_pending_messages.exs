defmodule QuckChatRealtime.Repo.Migrations.CreatePendingMessages do
  use Ecto.Migration

  def change do
    create table(:pending_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :message_id, :string, null: false
      add :conversation_id, :string, null: false
      add :sender_id, :string, null: false
      add :recipient_id, :string, null: false
      add :message_type, :string, default: "text"
      add :content, :text
      add :metadata, :map, default: %{}
      add :priority, :integer, default: 0
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Index for fetching pending messages for a user
    create index(:pending_messages, [:recipient_id, :priority, :inserted_at])

    # Index for cleanup of expired messages
    create index(:pending_messages, [:expires_at])

    # Unique constraint to prevent duplicate queue entries
    create unique_index(:pending_messages, [:message_id, :recipient_id])
  end
end
