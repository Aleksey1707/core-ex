defmodule Core.EsFixture.Account.Event do
  @moduledoc """
  События счёта: с нагрузкой (`Opened`, `Renamed`, `HolderSet` — с ПДн), без неё (`Frozen`,
  `Closed`) и удалённый тип `Verified` — его больше не пишут, но записанные читаются.
  """

  alias Core.EsFixture.Account.Event.Closed
  alias Core.EsFixture.Account.Event.Frozen
  alias Core.EsFixture.Account.Event.HolderSet
  alias Core.EsFixture.Account.Event.Opened
  alias Core.EsFixture.Account.Event.Renamed
  alias Core.EsFixture.Account.Event.Verified
  alias Core.EsFixture.UserID

  use Core.Es.Event.Family,
    aggregate: Core.EsFixture.Account,
    aggregate_id: Core.EsFixture.Account.ID,
    by: UserID,
    codec: Core.EsFixture.Account.Event.Codec

  @type t :: Opened.t() | Renamed.t() | HolderSet.t() | Frozen.t() | Closed.t() | Verified.t()
end
