defmodule Core.EsFixture.Account.Event.Verified do
  @moduledoc "Счёт проверен. Тип удалён: событие больше не пишется."

  alias Core.EsFixture.Account
  alias Core.EsFixture.UserID

  use Core.Es.Event,
    aggregate_id: Account.ID,
    by: UserID,
    payload: nil
end
