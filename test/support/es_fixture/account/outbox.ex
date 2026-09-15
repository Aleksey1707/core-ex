defmodule Core.EsFixture.Account.Outbox do
  @moduledoc "Маппинг событий счёта в записи outbox."

  use Core.Es.Outbox,
    topic: "accounts",
    event: Core.EsFixture.Account.Event
end
