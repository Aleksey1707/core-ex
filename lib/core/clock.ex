defmodule Core.Clock do
  @moduledoc """
  Доменное время: «сейчас», которое видит домен (ADR-0083).

  Через шов идут `now/0` и `now!/0` у `use Core.Prim.DateTime`, `today/0` и `today!/0` у
  `use Core.Prim.Date` и прямой вызов `now/0`. Реализацию выбирает `config :core, clock:`, ключ
  читается на каждый вызов; по умолчанию — `Core.Clock.System`. В тестах — `Core.Clock.Test`.

  Инфраструктура библиотеки (время записей outbox, аренды, поллер, cleaner, хранилище ключей
  субъектов, читатель проекции, метрики) берёт реальное время явно и шва не видит.
  """

  alias Core.Config

  @doc "Текущее время: UTC `DateTime` с микросекундами."
  @callback now() :: DateTime.t()

  @doc "Доменное «сейчас»: UTC `DateTime` с микросекундами от реализации из `Core.Config.clock/0`."
  @spec now() :: DateTime.t()

  def now, do: Config.clock().now()
end
