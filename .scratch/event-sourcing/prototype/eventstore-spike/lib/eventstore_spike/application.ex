defmodule EventstoreSpike.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if System.get_env("SPIKE_NO_CHILDREN") == "1",
        do: [],
        else: [EventstoreSpike.Repo]

    Supervisor.start_link(children, strategy: :one_for_one, name: EventstoreSpike.Supervisor)
  end
end
