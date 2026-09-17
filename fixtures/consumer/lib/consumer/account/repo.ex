defmodule Consumer.Account.Repo do
  use Core.Es.Aggregate.Repo,
    aggregate: Consumer.Account,
    id: Consumer.Account.ID
end
