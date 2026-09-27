defmodule Consumer.Domain.Sales.Common.Account.Process do
  use Core.Es.Aggregate.Process,
    repo: Consumer.Domain.Sales.Common.Account.Repo
end
