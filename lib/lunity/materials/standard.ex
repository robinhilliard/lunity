defmodule Lunity.Materials.Standard do
  @moduledoc """
  Built-in material palette for quick prototyping.

  Provides common PBR presets so you can get visual variation without
  defining custom materials or importing GLBs.

      node :ball,   material: Lunity.Materials.Standard.white
      node :floor,  material: Lunity.Materials.Standard.dark_grey
      node :wall,   material: Lunity.Materials.Standard.brushed_metal
  """

  use Lunity.Materials

  # ---------------------------------------------------------------------------
  # Basic colors (dielectric/plastic, roughness 0.5)
  # ---------------------------------------------------------------------------
  material(:white, base_color: {1.0, 1.0, 1.0}, metallic: 0.0, roughness: 0.5)
  material(:black, base_color: {0.05, 0.05, 0.05}, metallic: 0.0, roughness: 0.5)
  material(:red, base_color: {0.8, 0.1, 0.1}, metallic: 0.0, roughness: 0.5)
  material(:green, base_color: {0.1, 0.7, 0.2}, metallic: 0.0, roughness: 0.5)
  material(:blue, base_color: {0.1, 0.3, 0.9}, metallic: 0.0, roughness: 0.5)
  material(:yellow, base_color: {0.9, 0.8, 0.1}, metallic: 0.0, roughness: 0.5)
  material(:orange, base_color: {0.9, 0.4, 0.05}, metallic: 0.0, roughness: 0.5)
  material(:purple, base_color: {0.5, 0.1, 0.8}, metallic: 0.0, roughness: 0.5)
  material(:cyan, base_color: {0.1, 0.8, 0.8}, metallic: 0.0, roughness: 0.5)

  # ---------------------------------------------------------------------------
  # Greys
  # ---------------------------------------------------------------------------
  material(:light_grey, base_color: {0.8, 0.8, 0.8}, metallic: 0.0, roughness: 0.5)
  material(:grey, base_color: {0.5, 0.5, 0.5}, metallic: 0.0, roughness: 0.5)
  material(:dark_grey, base_color: {0.2, 0.2, 0.2}, metallic: 0.0, roughness: 0.5)

  # ---------------------------------------------------------------------------
  # Metals
  # ---------------------------------------------------------------------------
  material(:metal_silver, base_color: {0.95, 0.93, 0.88}, metallic: 1.0, roughness: 0.3)
  material(:metal_gold, base_color: {1.0, 0.76, 0.33}, metallic: 1.0, roughness: 0.3)
  material(:metal_copper, base_color: {0.95, 0.64, 0.54}, metallic: 1.0, roughness: 0.3)
  material(:brushed_metal, base_color: {0.7, 0.7, 0.7}, metallic: 1.0, roughness: 0.6)

  # ---------------------------------------------------------------------------
  # Common surfaces
  # ---------------------------------------------------------------------------
  material(:rubber, base_color: {0.15, 0.15, 0.15}, metallic: 0.0, roughness: 0.9)

  material(:glass,
    base_color: {0.9, 0.95, 1.0},
    metallic: 0.0,
    roughness: 0.05,
    alpha_mode: :blend
  )

  material(:mirror, base_color: {0.95, 0.95, 0.95}, metallic: 1.0, roughness: 0.0)

  # ---------------------------------------------------------------------------
  # Emissive
  # ---------------------------------------------------------------------------
  material(:glow_red,
    base_color: {1.0, 0.2, 0.1},
    metallic: 0.0,
    roughness: 0.5,
    emissive: {1.0, 0.2, 0.1}
  )

  material(:glow_green,
    base_color: {0.2, 1.0, 0.2},
    metallic: 0.0,
    roughness: 0.5,
    emissive: {0.2, 1.0, 0.2}
  )

  material(:glow_blue,
    base_color: {0.2, 0.4, 1.0},
    metallic: 0.0,
    roughness: 0.5,
    emissive: {0.2, 0.4, 1.0}
  )

  material(:glow_white,
    base_color: {1.0, 1.0, 1.0},
    metallic: 0.0,
    roughness: 0.5,
    emissive: {1.0, 1.0, 1.0}
  )
end
