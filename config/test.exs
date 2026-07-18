import Config

# Tests rely on Application.put_env in setup; keep nil from config.exs unless a test needs defaults.

# Keep ECS tests on BinaryBackend for deterministic CI without GPU hardware.
config :lunity, :nx, backend: :binary
