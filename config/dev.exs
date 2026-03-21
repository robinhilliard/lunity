import Config

# Local development only — do not use in production. Override per deploy via runtime / secrets.
config :lunity, :player_ws_token, "dev_player_ws_token"
config :lunity, :player_jwt_secret, "dev_player_jwt_secret"
config :lunity, :player_mint_secret, "dev_player_mint_key"
