defmodule Blind.Order.Process do
  use Core.Es.Aggregate.Process,
    repo: Blind.Order.Repo
end
