defmodule Consumer.Order.Repo do
  use Core.Es.Aggregate.Repo,
    aggregate: Consumer.Order,
    id: Consumer.Order.ID
end
