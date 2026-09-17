defmodule Blind.Account.Repo.Pg do
  alias Blind.Account

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Blind.Account.Repo,
    aggregate: Account,
    id: Account.ID,
    errors: Account.Errors,
    outbox: Account.Outbox
end
