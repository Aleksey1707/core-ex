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
  """

  alias Core.Error
  alias Core.Mq.Message
  alias Core.Result

  @type t :: term()

  @callback get(t(), timeout()) :: {:ok, Message.t()} | :empty | {:error, Error.t()}
  @callback commit(t()) :: Result.unit()
  @callback default_poll_interval_ms() :: pos_integer()
  @callback notify_when_ready(t(), pid()) :: Result.t(reference())

  @optional_callbacks default_poll_interval_ms: 0, notify_when_ready: 2
end
