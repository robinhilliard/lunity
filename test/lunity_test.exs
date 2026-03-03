defmodule LunityTest do
  use ExUnit.Case
  doctest Lunity
  doctest Lunity.Extras

  test "greets the world" do
    assert Lunity.hello() == :world
  end
end
