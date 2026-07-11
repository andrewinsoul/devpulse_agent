defmodule DevpulseAgent.RunnerSupervisor do
  @moduledoc """
  Supervises the long-running agent worker for `devpulse start`.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    supervisor_name = Keyword.get(opts, :name, __MODULE__)

    child_opts =
      opts
      |> Keyword.delete(:name)
      |> Keyword.put(:supervisor, supervisor_name)

    child =
      {DevpulseAgent.Agent, child_opts}
      |> Supervisor.child_spec(restart: :transient)

    Supervisor.init([child], strategy: :one_for_one)
  end
end
