defmodule Lunity.Auth.PlayerJWT do
  @moduledoc """
  HS256 JWTs for `PlayerSocket` `auth` messages (Phase 2).

  Claims:
  - **`user_id`** (required) — stable account id after OAuth / minted session.
  - **`player_id`** (optional) — logical player slot; defaults to `user_id` when absent.

  Configure `Application.get_env(:lunity, :player_jwt_secret)` with a long random secret.
  """

  use Joken.Config

  @impl true
  def token_config do
    default_claims(default_exp: 60 * 60)
    |> add_claim("user_id", fn -> nil end, &is_binary/1)
    |> add_claim("player_id", fn -> nil end, fn val -> is_binary(val) or is_nil(val) end)
  end

  @doc """
  Verifies signature and validates claims using `:player_jwt_secret`.
  """
  @spec verify_and_validate_token(String.t()) ::
          {:ok, map()} | {:error, term()}
  def verify_and_validate_token(bearer_token) when is_binary(bearer_token) do
    case Application.get_env(:lunity, :player_jwt_secret) do
      secret when is_binary(secret) and secret != "" ->
        signer = Joken.Signer.create("HS256", secret)
        verify_and_validate(bearer_token, signer)

      _ ->
        {:error, :missing_jwt_secret}
    end
  end

  @doc "Build a signer for tests or tooling."
  @spec signer_from_secret(String.t()) :: Joken.Signer.t()
  def signer_from_secret(secret) when is_binary(secret) do
    Joken.Signer.create("HS256", secret)
  end
end
