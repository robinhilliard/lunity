defmodule Lunity.Nx.HostTest do
  use ExUnit.Case, async: true

  alias Lunity.Nx.Host

  test "to_list and to_number round-trip host values" do
    t = Nx.tensor([1, 2, 3], type: :s32)
    assert Host.to_list(t) == [1, 2, 3]
    assert Host.to_number(t[1]) == 2
  end

  test "from_host creates tensors on the default backend" do
    t = Host.from_host([4, 5], type: :s32)
    assert Nx.shape(t) == {2}
    assert Host.to_list(t) == [4, 5]
  end

  test "to_host transfers to BinaryBackend" do
    t = Host.from_host([9], type: :f32)
    host = Host.to_host(t)
    assert Host.to_list(host) == [9.0]
  end
end
