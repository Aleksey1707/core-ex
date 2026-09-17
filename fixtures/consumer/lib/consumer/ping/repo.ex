defmodule Consumer.Ping.Repo do
  use Core.Es.Aggregate.Repo,
    aggregate: Consumer.Ping,
    id: Consumer.Ping.ID
end
