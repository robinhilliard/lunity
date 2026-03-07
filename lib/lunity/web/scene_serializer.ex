defmodule Lunity.Web.SceneSerializer do
  @moduledoc """
  Serializes an EAGL.Scene into JSON-friendly maps for the WebGL viewer.

  Computes world matrices on the server using EAGL's exact transform
  pipeline and sends them directly. The viewer applies these matrices
  as-is, guaranteeing identical rendering.
  """

  import EAGL.Math

  def serialize(%EAGL.Scene{} = scene) do
    identity = mat4_identity()
    nodes = Enum.flat_map(scene.root_nodes, &serialize_node(&1, identity))
    %{nodes: nodes}
  end

  defp serialize_node(node, parent_world) do
    local = EAGL.Node.get_local_transform_matrix(node)
    world = mat4_mul(parent_world, local)

    if node.name == "scene_root" do
      Enum.flat_map(node.children || [], &serialize_node(&1, world))
    else
      node_map = %{
        name: node.name,
        world_matrix: mat4_to_list(world),
        glb_id: get_in(node.properties || %{}, ["glb_id"]),
        has_mesh: has_mesh?(node),
        material: serialize_material(node),
        light: serialize_light(node)
      }

      [node_map]
    end
  end

  defp has_mesh?(node) do
    node.mesh != nil or Enum.any?(node.children || [], &has_mesh?/1)
  end

  defp mat4_to_list([{m0, m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, m12, m13, m14, m15}]) do
    [m0, m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, m12, m13, m14, m15]
  end

  defp serialize_material(node) do
    case find_material_uniforms(node) do
      nil ->
        nil

      uniforms ->
        [{br, bg, bb}] = Keyword.get(uniforms, :"material.baseColor", [{1.0, 1.0, 1.0}])
        [{er, eg, eb}] = Keyword.get(uniforms, :"material.emissive", [{0.0, 0.0, 0.0}])
        metallic = Keyword.get(uniforms, :"material.metallic", 1.0)
        roughness = Keyword.get(uniforms, :"material.roughness", 1.0)

        %{
          baseColor: [br, bg, bb],
          emissive: [er, eg, eb],
          metallic: metallic,
          roughness: roughness
        }
    end
  end

  defp find_material_uniforms(node) do
    node.material_uniforms ||
      Enum.find_value(node.children || [], &find_material_uniforms/1)
  end

  defp serialize_light(node) do
    case node.light do
      nil ->
        nil

      %{type: type, color: {r, g, b}, intensity: intensity} = light ->
        %{
          type: type,
          color: [r, g, b],
          intensity: intensity,
          range: light[:range]
        }
    end
  end
end
