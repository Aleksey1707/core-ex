defmodule Consumer.Account.Process do
  use Core.Es.Aggregate.Process,
    repo: Consumer.Account.Repo
end
