defmodule Core.Mq.ReaderReliable do
  @moduledoc """
  Контракт надёжного чтения: `commit` фиксирует offset/cursor.

  Единственный контракт чтения в библиотеке: `Core.PubSub.MqSubscriberReliable` работает
  только с ним, и подписчику без commit'а подключиться некуда. Как и у `Mq.Writer`,
  представление на проводе задаёт адаптер (`10-architecture.md`).

  Как и там, `{:error, _}` покрывает отказ брокера, а не самого reader'а: за handle стоит
  процесс (`Mq.Stream.Reader` — `GenServer.call`), и мёртвый или зависший reader приходит
  `exit`. Вызывающий, которому нельзя падать вместе с ним, ловит `exit` сам
  (`Core.PubSub.MqSubscriberReliable`).

  Необязательный `default_poll_interval_ms/0` — интервал опроса, который подписчик берёт, когда
  `poll_interval_ms:` не задан. Его объявляет reader, у которого пустой `get` дорог: запрос в базу
  у `Core.Mq.Dlq.Reader`, а не чтение буфера в памяти, как у читателей брокеров.

  Необязательный `notify_when_ready/2` — заявка на готовность: reader один раз шлёт процессу
  `{:mq_ready, ref}`, когда ему есть что отдать (сразу, если есть уже сейчас), и забывает заявку.
  Заявка у reader'а одна — новая заменяет прежнюю. Ответ может оказаться ложным: `get` после него
  вправе вернуть `:empty`. Reader с заявкой подписчик не опрашивает в простое
  (`Core.PubSub.MqSubscriberReliable`), а следит за ним монитором, поэтому handle такого reader'а —
  процесс, который находит `GenServer.whereis/1`.

  Необязательный `snapshot/1` — снимок состояния reader'а одной формой для метрик: топик,
  длина буфера, остаток чанка, признак сообщения в работе и его возраст в секундах, признак
  подписки/аренды и `details` для подробностей адаптера. Возраст считает reader, поэтому
  плагин не разбирает timestamp чанка.

  Необязательный `metrics/1` — значения gauge'ей reader'а: карта с `:topic` (строка) и числовыми
  значениями по остальным ключам. Его предпочитает плагин `Core.Mq.PromEx`, `info/1` остаётся
  запасным путём: новый читатель даёт метрики, не правя плагин. Reader без всех метрик плагин
  пропускает, а не роняет сбор.
  """

  alias Core.Error
  alias Core.Mq.Message
  alias Core.Result

  @typedoc """
  Снимок состояния reader'а: общие gauge'и и `details` адаптера.

  `pending_age_seconds` — возраст сообщения в работе от записи чанка брокером; без сообщения — 0.
  `subscribed?` — подписка у читателей брокеров, аренда у Kafka. `details` — подробности адаптера.
  """
  @type snapshot :: %{
          required(:topic) => String.t(),
          required(:buffer_len) => non_neg_integer(),
          required(:chunk_remaining) => non_neg_integer(),
          required(:pending?) => boolean(),
          required(:pending_age_seconds) => number(),
          required(:subscribed?) => boolean(),
          required(:details) => map()
        }

  @typedoc "Значения gauge'ей reader'а: `:topic` и числа по ключам метрик."
  @type metrics :: %{required(:topic) => String.t(), optional(atom()) => number()}

  @type t :: term()

  @callback get(t(), timeout()) :: {:ok, Message.t()} | :empty | {:error, Error.t()}
  @callback commit(t()) :: Result.unit()
  @callback default_poll_interval_ms() :: pos_integer()
  @callback notify_when_ready(t(), pid()) :: Result.t(reference())
  @callback metrics(t()) :: metrics()
  @callback snapshot(t()) :: snapshot()

  @optional_callbacks default_poll_interval_ms: 0, notify_when_ready: 2, metrics: 1, snapshot: 1
end
