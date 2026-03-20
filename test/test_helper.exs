# Ensure test support modules are loaded
Code.require_file("support/mock_component.ex", __DIR__)
Code.require_file("support/test_behaviour.ex", __DIR__)
Code.require_file("support/test_prefab.ex", __DIR__)
Code.require_file("support/hot_reload_scene.ex", __DIR__)
Code.require_file("support/hot_reload_entity.ex", __DIR__)
Code.require_file("support/hot_reload_manager.ex", __DIR__)

ExUnit.start()
