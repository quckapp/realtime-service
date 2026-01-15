defmodule QuckAppRealtime.Repo do
  @moduledoc """
  MySQL Repository for QuckApp Realtime.

  Used for:
  - Message queue persistence (store-and-forward)
  - Call history
  - Session management
  - Analytics
  """
  use Ecto.Repo,
    otp_app: :quckapp_realtime,
    adapter: Ecto.Adapters.MyXQL
end
