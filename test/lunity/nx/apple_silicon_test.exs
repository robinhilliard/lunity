defmodule Lunity.Nx.AppleSiliconTest do
  use Lunity.AppleSiliconCase, async: false
  import Nx.Defn

  alias Lunity.Nx.Backend
  alias Lunity.Nx.Host

  test "auto selects an MLX backend on Apple Silicon", %{choice: choice} do
    assert choice.name in [:emily, :emlx]
    assert choice.detail =~ "device="
  end

  test "configure!(:emily) applies Emily when available" do
    choice = Backend.configure!(backend: :emily)
    assert choice.name == :emily

    case Nx.default_backend() do
      {Emily.Backend, _} -> :ok
      Emily.Backend -> :ok
      other -> flunk("expected Emily.Backend, got #{inspect(other)}")
    end
  end

  test "from_host creates tensors on the MLX backend" do
    t = Host.from_host([1.0, 2.0, 3.0], type: :f32)
    assert mlx_tensor?(t)
    assert Host.to_list(t) == [1.0, 2.0, 3.0]
  end

  test "device arithmetic round-trips through Host" do
    a = Host.from_host([[1.0, 2.0], [3.0, 4.0]], type: :f32)
    b = Host.from_host([[10.0, 20.0], [30.0, 40.0]], type: :f32)

    sum = Nx.add(a, b)
    assert mlx_tensor?(sum)
    assert Host.to_list(sum) == [11.0, 22.0, 33.0, 44.0]
  end

  test "defn compiles and runs on the MLX compiler" do
    result = scaled_add(Host.from_host([1.0, 2.0, 3.0], type: :f32), 2.0)
    assert mlx_tensor?(result)
    assert Host.to_list(result) == [2.0, 4.0, 6.0]
  end

  defnp scaled_add(t, scale) do
    Nx.multiply(t, scale)
  end

  defp mlx_tensor?(%Nx.Tensor{data: %struct{}}) do
    struct in [Emily.Backend, EMLX.Backend]
  end
end
