defmodule Lunity.Mod.SandboxTest do
  use ExUnit.Case, async: true

  alias Lunity.Mod.Sandbox

  describe "new/0" do
    test "creates a luerl state" do
      st = Sandbox.new()
      assert is_tuple(st)
    end

    test "strips io module" do
      st = Sandbox.new()
      {:ok, [val], _st} = :luerl.do("return io", st)
      assert val == nil
    end

    test "strips os module" do
      st = Sandbox.new()
      {:ok, [val], _st} = :luerl.do("return os", st)
      assert val == nil
    end

    test "strips debug module" do
      st = Sandbox.new()
      {:ok, [val], _st} = :luerl.do("return debug", st)
      assert val == nil
    end

    test "keeps math module" do
      st = Sandbox.new()
      {:ok, [result], _st} = :luerl.do("return math.floor(3.7)", st)
      assert result == 3.0
    end

    test "keeps string module" do
      st = Sandbox.new()
      {:ok, [result], _st} = :luerl.do("return string.len(\"hello\")", st)
      assert result == 5.0
    end

    test "keeps table module" do
      st = Sandbox.new()
      {:ok, [result], _st} = :luerl.do("local t = {1,2,3}; return #t", st)
      assert result == 3.0
    end
  end

  describe "set_nested/3" do
    test "sets a nested value" do
      st = Sandbox.new()
      {:ok, _, st} = :luerl.do("foo = {bar = {}}", st)
      st = Sandbox.set_nested(st, ["foo", "bar", "baz"], 42.0)
      {:ok, [result], _st} = :luerl.do("return foo.bar.baz", st)
      assert result == 42.0
    end
  end
end
