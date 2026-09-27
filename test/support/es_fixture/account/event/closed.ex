defmodule Core.EsFixture.Account.Event.Closed do
  @moduledoc "Счёт закрыт."

  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID

  use Core.Es.Event,
    aggregate_id: Account.ID,
    by: UserID,
    payload: nil
end
