import Config

config :logger, level: :warning

# Game client WebSocket (`Lunity.Web.PlayerSocket`). Set in deploy secrets; tests use `put_env`.
config :lunity, :player_ws_token, nil

# HS256 secret for `PlayerSocket` `auth` JWTs (`Lunity.Auth.PlayerJWT`).
config :lunity, :player_jwt_secret, nil

# Interval for `subscribe_state` pushes (ms).
config :lunity, :player_state_push_interval_ms, 100
