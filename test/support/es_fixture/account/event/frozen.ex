defmodule Core.EsFixture.Account.Event.Frozen do
  @moduledoc "Счёт заморожен."

  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID

  use Core.Es.Event,
    aggregate_id: Account.ID,
    by: UserID,
    payload: nil
end
