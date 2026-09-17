defmodule Blind.Order.Repo do
  use Core.Es.Aggregate.Repo,
    aggregate: Blind.Order,
    id: Blind.Order.ID
end
