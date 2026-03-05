defmodule LunityTest do
  use ExUnit.Case

  test "project_app returns the configured app" do
    assert is_atom(Lunity.project_app())
  end
end
