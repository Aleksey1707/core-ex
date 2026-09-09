defmodule Core.Mq.Writer do
  @moduledoc """
  Контракт публикации сообщений в MQ.

  Контракт задаёт порядок и обработку ошибок, но **не** представление на проводе:
  `Mq.Message` — внутренняя модель, а её wire-формат выбирает адаптер
  (`Mq.Stream.Codec` заворачивает сообщение в JSON, `Mq.Kafka.Writer` пишет нативно).
  Правила и следствия для потребителей — `10-architecture.md`.

  ## Отказ writer'а

  `{:error, _}` покрывает отказ **брокера**, а не writer'а: за handle может стоять процесс
  (`Mq.Stream.Writer` — `GenServer.call`), и мёртвый или зависший writer приходит вызывающему
  `exit`, а не результатом. Ловит его тот, кто владеет единицей работы целиком:
  `Core.Outbox.Poller` — весь цикл (`:cycle_exit`, аренда снята, попытка записи не засчитана),
  `Core.PubSub.MqSubscriberReliable` — чтение и commit.

  Ниже по стеку `exit` в `{:error, _}` не превращается: «writer недоступен» и «брокер отверг
  запись» — разные факты, и выдав первое за второе, `Outbox.Delivery.Mq` засчитывал бы записи
  попытку публикации за недоступность процесса — вплоть до `:failed` на ровном месте.
  """

  alias Core.Error
  alias Core.Mq.Message

  @type t :: term()

  @callback put(t(), Message.t()) :: :ok | {:error, Error.t()}

  @doc """
  Опубликовать список сообщений строго по порядку.

  При первой ошибке — стоп; `index` — 0-based индекс первого непроуспешного.
  Уже отправленные сообщения не откатываются.
  """
  @callback put_many(t(), [Message.t()]) :: :ok | {:error, non_neg_integer(), Error.t()}
end
