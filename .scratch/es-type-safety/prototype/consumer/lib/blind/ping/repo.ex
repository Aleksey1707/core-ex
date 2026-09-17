defmodule Blind.Ping.Repo do
  use Core.Es.Aggregate.Repo,
    aggregate: Blind.Ping,
    id: Blind.Ping.ID
end
