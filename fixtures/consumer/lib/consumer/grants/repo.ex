defmodule Consumer.Grants.Repo do
  use Core.Es.Aggregate.Repo,
    aggregate: Consumer.Grants,
    id: Consumer.Grants.ID
end
