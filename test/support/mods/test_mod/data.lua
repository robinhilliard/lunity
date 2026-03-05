data:extend({
  {
    type = "scene",
    name = "test_scene",
    nodes = {
      { name = "box1", prefab = "box", position = {1, 2, 3}, scale = {1, 1, 1} },
      { name = "box2", prefab = "box", position = {4, 5, 6} },
    }
  },
  {
    type = "prefab",
    name = "box",
    glb = "box",
    properties = {
      tint = { type = "color", default = {1, 1, 1, 1} }
    }
  },
  {
    type = "entity",
    name = "player",
    properties = {
      health = { type = "integer", default = 100 },
      speed = { type = "float", default = 5.0 }
    },
    components = { "health", "movement" }
  }
})
