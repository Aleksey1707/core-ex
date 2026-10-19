defmodule Core.Outbox.Test do
  @moduledoc """
  Дублёр доставки outbox: записи доходят до подписчиков приложения без брокера, в sandbox теста
  (ADR-0082).

  Подписчики — список keyword в той же форме, что приложение отдаёт
  `Core.PubSub.MqSubscriberReliable` (элемент `subscriber:` дерева
  `Core.PubSub.MqSubscriberReliable.Supervisor`):

  - работают `topic`, `filter`, `from_message`, `on_message`, `context_factory`, `max_attempts`
    (по умолчанию 5) и `subscribe_data` — данные `on_message`, как у подписчика дерева;
  - `name` обязательна и различна у подписчиков: это имя курсора подписчика;
  - сетевые ключи (`reader_module`, `reader`, `dlq_*`, `subscribe`, `shutdown`, `poll_interval_ms`,
    `retry_max_ms`) игнорируются, неизвестный ключ — `ArgumentError`.

  Сообщение обрабатывает тот же шаг, что у настоящего подписчика: `filter`, span `process`,
  `from_message`, контекст, `on_message` и перехват исключения ведут себя одинаково.

  Записи резервирует и сохраняет `Core.Outbox.Repo` (`Core.Config.outbox_repo/0`), как поллер, со
  статусом `:published`. В `Core.Mq.Message` запись переводит `Core.Outbox.Delivery.Mq.to_message/1`:
  тело, ключ, заголовки записи и запечатанные ПДн — те, что ушли бы в брокер; транспортного
  `traceparent` span'а создания доставка в брокер добавляет, дублёр — нет. У каждого топика свой
  журнал, у каждого подписчика свой курсор; журналы, курсоры и мёртвые письма живут в процессе,
  который зовёт `drain/2`.

  Отличия от прода: повтор без backoff, а мёртвое письмо появляется и без `dlq_writer` у
  подписчика. Своё дерево outbox тест держит выключенным: дублёр его не трогает. ExUnit модуль
  не использует.
  """

  alias Core.Context
  alias Core.Exc
  alias Core.Helper.StartOpts
  alias Core.Mq
  alias Core.Mq.Message
  alias Core.Outbox
  alias Core.Outbox.Delivery
  alias Core.Outbox.Record
  alias Core.PubSub.MqSubscriberReliable.Step
  alias Core.Result

  require Logger

  @label "Outbox.Test"
  @state_key {__MODULE__, :state}

  @subscriber_keys ~w(
    reader_module reader filter from_message on_message context_factory poll_interval_ms retry_max_ms
    max_attempts dlq_writer dlq_handle dlq_topic topic subscribe subscribe_data name shutdown
  )a

  @default_max_attempts 5
  @batch_size Outbox.BatchSize.new!(100)
  @lock_duration Outbox.LockDuration.new!(60)
  @cursor %{position: 0, attempts: 0, error: nil}

  defmodule DeadLetter do
    @moduledoc """
    Мёртвое письмо дублёра: сообщение, которое подписчик не обработал.

    `reason` — `:exhausted` (исчерпаны `max_attempts`) или `:rejected` (отказ без повторов
    `{:reject, _}`); `subscriber` — `name` подписчика.
    """

    alias Core.Error
    alias Core.Mq.Message

    @enforce_keys ~w(topic subscriber message reason attempts error)a
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            topic: String.t(),
            subscriber: atom(),
            message: Message.t(),
            reason: :exhausted | :rejected,
            attempts: pos_integer(),
            error: Error.t()
          }
  end

  # ===== доставка =====

  @doc """
  Один проход доставки — синхронно, в процессе вызова.

  Проход публикует все записи `:new` в журналы топиков и ведёт каждого подписчика по журналу его
  топика от курсора до конца. Записи, которые обработчики сделали по ходу, уходят следующим
  вызовом: цепочку реакций гонят повторные вызовы.

  - Повтор с ошибкой держит подписчика на сообщении до следующего вызова; остальные подписчики и
    топики идут дальше.
  - Исчерпание `max_attempts` и отказ без повторов кладут сообщение в мёртвые письма
    (`dead_letters/1`) и сдвигают курсор.
  - Топик без подписчиков просто публикуется.

  `opts`: `context_factory:` — контекст вызовов `Core.Outbox.Repo` (по умолчанию
  `Core.Context.new/0`). Недопустимая опция или подписчик — `ArgumentError`; запись, которую
  нельзя перевести в сообщение, — `Core.Exc`, зарезервированная пачка при этом возвращается в `:new`.
  """
  @spec drain([keyword()], keyword()) :: :ok

  def drain(subscribers, opts \\ []) when is_list(subscribers) and is_list(opts) do
    StartOpts.keys!(@label, opts, [:context_factory])
    context = StartOpts.fun!(@label, opts, :context_factory, 0, &Context.new/0).()
    subscribers = parse_subscribers!(subscribers)

    state =
      Core.Config.outbox_repo()
      |> publish_new(state(), context)
      |> deliver_all(subscribers)

    Process.put(@state_key, state)
    :ok
  end

  # ---

  defp parse_subscribers!(subscribers) do
    parsed = Enum.map(subscribers, &parse_subscriber!/1)
    :ok = StartOpts.unique!(@label, :name, "различные name подписчиков", Enum.map(parsed, & &1.name))
    parsed
  end

  defp parse_subscriber!(opts) when is_list(opts) do
    StartOpts.keys!(@label, opts, @subscriber_keys)
    step = Step.new!(@label, opts)

    %{
      name: StartOpts.atom!(@label, opts, :name),
      topic: StartOpts.binary!(@label, opts, :topic),
      step: %{step | data: Keyword.get(opts, :subscribe_data)},
      max_attempts: StartOpts.pos_integer!(@label, opts, :max_attempts, @default_max_attempts)
    }
  end

  defp publish_new(repo, state, context) do
    case repo.fetch_and_reserve(@batch_size, @lock_duration, :all, context) do
      [] ->
        state

      records ->
        messages = to_messages!(repo, records, context)
        :ok = repo.save_results(mark_published(records), context)
        publish_new(repo, Enum.reduce(messages, state, &append_journal(&2, &1)), context)
    end
  end

  defp to_messages!(repo, records, context) do
    case Result.traverse(records, &Delivery.Mq.to_message/1) do
      {:ok, messages} ->
        messages

      {:error, error} ->
        :ok = repo.release(records, context)
        raise Exc, error
    end
  end

  defp mark_published(records) do
    published_at = Outbox.PublishedAt.now!()
    at = Outbox.UpdatedAt.now!()
    Enum.map(records, &Record.mark_published(&1, published_at, at))
  end

  defp append_journal(state, %Message{} = message) do
    topic = Mq.Topic.value(message.topic)
    update_in(state.journals, &Map.update(&1, topic, [message], fn journal -> journal ++ [message] end))
  end

  defp deliver_all(state, subscribers), do: Enum.reduce(subscribers, state, &deliver(&2, &1))

  defp deliver(state, subscriber) do
    cursor = Map.get(state.cursors, subscriber.name, @cursor)

    case Enum.at(Map.get(state.journals, subscriber.topic, []), cursor.position) do
      nil ->
        state

      %Message{} = message ->
        attempt = cursor.attempts + 1

        case handle(subscriber, message, attempt) do
          :advance ->
            deliver(put_cursor(state, subscriber, %{@cursor | position: cursor.position + 1}), subscriber)

          {:advance, %DeadLetter{} = dead_letter} ->
            state = %{state | dead_letters: state.dead_letters ++ [dead_letter]}
            deliver(put_cursor(state, subscriber, %{@cursor | position: cursor.position + 1}), subscriber)

          {:hold, error} ->
            put_cursor(state, subscriber, %{cursor | attempts: attempt, error: error})
        end
    end
  end

  defp handle(subscriber, message, attempt) do
    case Step.run(message, subscriber.step, attempt) do
      outcome when outcome in [:processed, :filtered] ->
        :advance

      {:reject, error} ->
        {:advance, dead_letter(subscriber, message, :rejected, attempt, error)}

      {:retry, error} when attempt >= subscriber.max_attempts ->
        {:advance, dead_letter(subscriber, message, :exhausted, attempt, error)}

      {:retry, error} ->
        {:hold, error}
    end
  end

  defp dead_letter(subscriber, message, reason, attempts, error) do
    Logger.warning(
      "#{@label}: сообщение в мёртвые письма: topic=#{subscriber.topic} " <>
        "subscriber=#{inspect(subscriber.name)} reason=#{reason} attempts=#{attempts} ошибка=#{error.message}"
    )

    %DeadLetter{
      topic: subscriber.topic,
      subscriber: subscriber.name,
      message: message,
      reason: reason,
      attempts: attempts,
      error: error
    }
  end

  defp put_cursor(state, subscriber, cursor),
    do: %{state | cursors: Map.put(state.cursors, subscriber.name, cursor)}

  # ===== мёртвые письма =====

  @doc """
  Мёртвые письма дублёра в порядке появления.

  `owner` — процесс, в котором шла доставка: для `drain/2` — процесс теста, `self()`.
  """
  @spec dead_letters(pid()) :: [DeadLetter.t()]

  def dead_letters(owner) when owner == self(), do: state().dead_letters

  # ===== общее =====

  defp state, do: Process.get(@state_key, %{journals: %{}, cursors: %{}, dead_letters: []})
end
