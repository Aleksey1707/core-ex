defmodule Blind.Account.Process do
  use Core.Es.Aggregate.Process,
    repo: Blind.Account.Repo
end
