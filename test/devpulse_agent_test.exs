defmodule DevpulseAgentTest do
  use ExUnit.Case
  doctest DevpulseAgent

  test "greets the world" do
    assert DevpulseAgent.hello() == :world
  end
end
