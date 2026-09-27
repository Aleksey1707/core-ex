defmodule Core.EsFixture.Account.Event do
  @moduledoc """
  События счёта: с нагрузкой (`Opened`, `Renamed`), без неё (`Frozen`, `Closed`) и удалённый тип
  `Verified` — его больше не пишут, но записанные читаются.
  """

  alias Core.EsFixture.Account.Event.Closed
  alias Core.EsFixture.Account.Event.Frozen
  alias Core.EsFixture.Account.Event.Opened
  alias Core.EsFixture.Account.Event.Renamed
  alias Core.EsFixture.Account.Event.Verified

  @type t :: Opened.t() | Renamed.t() | Frozen.t() | Closed.t() | Verified.t()
end
