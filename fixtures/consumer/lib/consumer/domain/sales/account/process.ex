defmodule Consumer.Domain.Sales.Account.Process do
  use Core.Es.Aggregate.Process,
    repo: Consumer.Domain.Sales.Account.Repo
end
