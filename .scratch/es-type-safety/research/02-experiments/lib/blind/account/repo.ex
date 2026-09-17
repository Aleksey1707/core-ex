defmodule Blind.Account.Repo do
  use Core.Es.Aggregate.Repo,
    aggregate: Blind.Account,
    id: Blind.Account.ID
end
