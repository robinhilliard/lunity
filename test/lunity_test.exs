defmodule LunityTest do
  use ExUnit.Case
  doctest Lunity

  test "greets the world" do
    assert Lunity.hello() == :world
  end
end
