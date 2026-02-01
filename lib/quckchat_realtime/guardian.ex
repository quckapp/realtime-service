defmodule QuckAppRealtime.Guardian do
  @moduledoc """
  Guardian implementation for JWT authentication.
  Compatible with the Spring Boot auth-service JWT tokens.

  The JWT contains:
  - sub: Spring auth-service user UUID
  - externalId: MongoDB ObjectId (used by NestJS for conversations)
  """

  use Guardian, otp_app: :quckapp_realtime

  @doc """
  Extract user ID from JWT claims (sub claim).
  """
  def subject_for_token(user_id, _claims) when is_binary(user_id) do
    {:ok, user_id}
  end

  def subject_for_token(%{id: id}, _claims) do
    {:ok, to_string(id)}
  end

  def subject_for_token(_, _), do: {:error, :invalid_resource}

  @doc """
  Build resource from JWT claims - returns user_id.
  """
  def resource_from_claims(%{"sub" => user_id}) when is_binary(user_id) do
    {:ok, user_id}
  end

  def resource_from_claims(_claims), do: {:error, :invalid_claims}

  @doc """
  Verify a token and extract user_id along with externalId (MongoDB ObjectId).
  Used for WebSocket authentication.

  Returns {:ok, %{user_id: string, external_id: string | nil}} on success.
  """
  def verify_token(token) when is_binary(token) do
    case decode_and_verify(token) do
      {:ok, claims} ->
        case claims do
          %{"sub" => user_id} when is_binary(user_id) ->
            # externalId is the MongoDB ObjectId used by NestJS
            external_id = claims["externalId"]
            {:ok, %{user_id: user_id, external_id: external_id}}

          _ ->
            {:error, :invalid_claims}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def verify_token(_), do: {:error, :invalid_token}
end
