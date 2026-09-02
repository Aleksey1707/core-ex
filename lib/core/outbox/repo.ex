defmodule Core.Outbox.Repo do
  @moduledoc """
  Контракт репозитория transactional outbox.
  """

  alias Core.Context
  alias Core.Outbox
  alias Core.Outbox.Record

  @callback append([Record.t()], Context.t()) :: :ok

  @doc "То же, с опциями запроса (`:prefix`, `:timeout`)."
  @callback append([Record.t()], Context.t(), keyword()) :: :ok

  @callback fetch_and_reserve(Outbox.BatchSize.t(), Outbox.LockDuration.t(), Context.t()) :: [
              Record.t()
            ]

  @callback fetch_and_reserve(
              Outbox.BatchSize.t(),
              Outbox.LockDuration.t(),
              Outbox.topics_filter(),
              Context.t()
            ) :: [Record.t()]

  @doc """
  Сохранить результаты доставки под токеном аренды (`Record.lease_id`).

  Строка, чью аренду перехватил другой поллер, и строка, удалённая `Cleaner`,
  не обновляются: результат прежнего владельца отбрасывается, запись не воскресает.
  """
  @callback save_results([Record.t()], Context.t()) :: :ok

  @doc """
  Снять аренду с зарезервированных записей — вернуть в `:new` под тем же токеном.

  Для прерванного цикла: без неё записи остаются `:in_work` до истечения аренды.
  `attempts` и история ошибок не меняются.
  """
  @callback release([Record.t()], Context.t()) :: :ok

  @callback delete_published_before(Outbox.PublishedAt.t(), Context.t()) :: non_neg_integer()

  @doc """
  Вернуть терминально проваленные записи (`:failed`) в очередь (`:new`).

  Оператор вызывает после разбора причины: `attempts` сбрасывается, аренда снимается.
  `:all` — все `:failed`; список id — только указанные. Возвращает число возвращённых.
  """
  @callback requeue_failed(:all | [Outbox.ID.t()], Context.t()) :: non_neg_integer()

  @doc "Число записей по каждому статусу (отсутствующие статусы → 0)."
  @callback counts_by_status() :: %{Outbox.Status.t() => non_neg_integer()}

  @doc "Возраст самой старой записи статуса в секундах; `nil`, если записей нет."
  @callback oldest_age_seconds(Outbox.Status.t()) :: non_neg_integer() | nil

  @doc "Число `:in_work` с истёкшим `locked_until`."
  @callback expired_lock_count() :: non_neg_integer()
end
