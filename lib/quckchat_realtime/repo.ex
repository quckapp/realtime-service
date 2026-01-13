defmodule QuckChatRealtime.Repo do
  @moduledoc """
  MySQL Repository for QuckChat Realtime.

  Used for:
  - Message queue persistence (store-and-forward)
  - Call history
  - Session management
  - Analytics
  """
  use Ecto.Repo,
    otp_app: :quckchat_realtime,
    adapter: Ecto.Adapters.MyXQL
end
