defmodule DevpulseAgent.Env do
  @env Mix.env()

  def dev?, do: @env == :dev
end
