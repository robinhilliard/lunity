# Ensure test support modules are loaded
Code.require_file("support/mock_component.ex", __DIR__)
Code.require_file("support/test_behaviour.ex", __DIR__)
Code.require_file("support/test_prefab.ex", __DIR__)
Code.require_file("support/hot_reload_scene.ex", __DIR__)
Code.require_file("support/hot_reload_entity.ex", __DIR__)
Code.require_file("support/hot_reload_manager.ex", __DIR__)
Code.require_file("support/player_socket_integration_client.ex", __DIR__)
Code.require_file("support/apple_silicon_case.ex", __DIR__)

# Default suite stays on BinaryBackend (see config/test.exs). Opt into Metal
# GPU coverage with: mix test --include apple_silicon  (or mix test.apple_silicon)
ExUnit.start(exclude: [:apple_silicon])
