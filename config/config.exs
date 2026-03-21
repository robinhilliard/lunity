import Config

config :logger, level: :warning

# Game client WebSocket (`Lunity.Web.PlayerSocket`). Set in deploy secrets; tests use `put_env`.
config :lunity, :player_ws_token, nil

# HS256 secret for `PlayerSocket` `auth` JWTs (`Lunity.Auth.PlayerJWT`).
config :lunity, :player_jwt_secret, nil

# Interval for `subscribe_state` pushes (ms).
config :lunity, :player_state_push_interval_ms, 100

# When set, POST /api/player/token (header X-Player-Mint-Key) can mint JWTs for dev / trusted backends.
config :lunity, :player_mint_secret, nil

# Optional {module, function} — server assigns instance/entity/spawn on `join` (see `Lunity.Web.PlayerJoin`).
config :lunity, :player_join, nil

import_config "#{config_env()}.exs"
