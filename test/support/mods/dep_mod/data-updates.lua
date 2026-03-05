-- Patch the test_mod's player entity
local player = data.entities["player"]
if player then
  player.properties.speed.default = 10.0
end

-- Add a node to the test scene
table.insert(data.scenes["test_scene"].nodes, {
  name = "powerup",
  prefab = "box",
  position = {7, 8, 9}
})
