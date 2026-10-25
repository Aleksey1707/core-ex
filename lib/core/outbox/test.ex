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
  который зовёт `drain/2`. Тест через HTTP гонит `drain/2` реактором `Core.Outbox.Test.Reactor` и
  перед проверками ждёт тишины `settle/2`.

  Отличия от прода: повтор без backoff, а мёртвое письмо появляется и без `dlq_writer` у
  подписчика. Своё дерево outbox тест держит выключенным: дублёр его не трогает. ExUnit модуль
  не использует.
  """

  use Core.Options

  alias Core.Context
  alias Core.Error
  alias Core.Exc
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

  @network_keys ~w(
    reader_module reader poll_interval_ms retry_max_ms dlq_writer dlq_handle dlq_topic subscribe shutdown
  )a
  @subscriber_keys [
    name: [type: {:custom, Core.Options.Type, :atom, []}, required: true, doc: "Имя курсора подписчика."],
    max_attempts: [type: :pos_integer, default: 5, doc: "Попыток до мёртвого письма."],
    subscribe_data: [type: :any, doc: "Данные подписки для `on_message`."]
  ]
  @subscriber_schema Step.schema()
                     |> Keyword.update!(:topic, &Keyword.put(Keyword.delete(&1, :default), :required, true))
                     |> Kernel.++(@subscriber_keys)
                     |> Kernel.++(Enum.map(@network_keys, &{&1, [type: :any, doc: "Сетевой ключ: игнорируется."]}))
  @subscribers_schema NimbleOptions.new!(
                        subscribers: [
                          type: {:list, {:keyword_list, @subscriber_schema}},
                          required: true,
                          doc: "Подписчики в форме `Core.PubSub.MqSubscriberReliable`."
                        ]
                      )
  @batch_size Outbox.BatchSize.new!(100)
  @lock_duration Outbox.LockDuration.new!(60)
  @cursor %{position: 0, attempts: 0, error: nil}
  @settle_timeout_ms 5_000
  @settle_poll_ms 10
  @call_timeout_ms 5_000
  @report_grace_ms 1_000
  @tag_header Mq.HeaderKey.new!("name")
  @event_id_header Mq.HeaderKey.new!("event_id")

  defmodule NotSettled do
    @moduledoc "Доставка не затихла к пределу `Core.Outbox.Test.settle/2` или дала мёртвое письмо."

    defexception [:message]
  end

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

  @typedoc false
  @type report :: %{
          new: non_neg_integer(),
          stuck: [
            %{
              topic: String.t(),
              subscriber: atom(),
              message: Message.t(),
              attempts: non_neg_integer(),
              error: Error.t() | nil
            }
          ],
          dead_letters: [DeadLetter.t()]
        }

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

  Недопустимая опция или подписчик — `ArgumentError`; запись, которую нельзя перевести в
  сообщение, — `Core.Exc`, зарезервированная пачка при этом возвращается в `:new`.
  """
  @opts_schema [
    context_factory: [
      type: {:fun, 0},
      default: &Context.new/0,
      doc: "Фабрика контекста вызовов `Core.Outbox.Repo`."
    ]
  ]
  @spec drain([keyword()], keyword()) :: :ok

  def drain(subscribers, opts \\ []) when is_list(subscribers) and is_list(opts) do
    context = Keyword.fetch!(opts, :context_factory).()
    subscribers = parse_subscribers!(subscribers, "#{inspect(__MODULE__)}.drain/2")

    state =
      Core.Config.outbox_repo()
      |> publish_new(state(), context)
      |> deliver_all(subscribers)

    Process.put(@state_key, state)
    :ok
  end

  # ---

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
    now = DateTime.utc_now()
    published_at = Outbox.PublishedAt.new!(now)
    at = Outbox.UpdatedAt.new!(now)
    Enum.map(records, &Record.mark_published(&1, published_at, at))
  end

  defp append_journal(state, %Message{} = message) do
    topic = Mq.Topic.value(message.topic)
    update_in(state.journals, &Map.update(&1, topic, [message], fn journal -> journal ++ [message] end))
  end

  defp deliver_all(state, subscribers), do: Enum.reduce(subscribers, state, &deliver(&2, &1))

  defp deliver(state, subscriber) do
    cursor = cursor(state, subscriber)

    case next_message(state, subscriber, cursor) do
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
        "subscriber=#{inspect(subscriber.name)} reason=#{reason} attempts=#{attempts} error=#{error.message}"
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

  `owner` — процесс, в котором шла доставка: для `drain/2` — процесс теста, `self()`; для
  реактора — сам реактор (`Core.Outbox.Test.Reactor`).
  """
  @spec dead_letters(GenServer.server()) :: [DeadLetter.t()]

  def dead_letters(owner) when owner == self(), do: state().dead_letters
  def dead_letters(reactor), do: GenServer.call(reactor, :dead_letters, @call_timeout_ms)

  # ===== тишина =====

  @doc """
  Дождаться тишины реактора — перед проверками приёмочного теста.

  Тишина — три условия разом: в outbox нет записей `:new`, курсоры всех подписчиков в конце
  журналов и ни один подписчик не застрял на ошибке.

  Упавший проход реактора и реактор, не ответивший к пределу, — тоже `NotSettled`. Недопустимая
  опция — `ArgumentError`.
  """
  @opts_schema [
    timeout: [
      type: :pos_integer,
      default: @settle_timeout_ms,
      doc:
        "Предел ожидания, мс. По пределу — `Core.Outbox.Test.NotSettled` со списком застрявших: топик, тег, " <>
          "`event_id`, подписчик, попытки, последняя ошибка."
    ],
    dead_letters: [
      type: {:in, ~w(fail allow)a},
      default: :fail,
      doc:
        "`:fail` — мёртвое письмо сразу даёт `NotSettled` со списком писем; `:allow` — письма тишине не " <>
          "мешают, их читает `dead_letters/1`."
    ]
  ]
  @spec settle(GenServer.server(), keyword()) :: :ok

  def settle(reactor, opts \\ []) when is_list(opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    dead_letters = Keyword.fetch!(opts, :dead_letters)
    await_settled(reactor, dead_letters, timeout, System.monotonic_time(:millisecond) + timeout)
  end

  # ---

  defp await_settled(reactor, dead_letters, timeout, deadline) do
    case request_report(reactor, timeout, deadline) do
      {:ok, report} ->
        check_settled(report, reactor, dead_letters, timeout, deadline)

      {:crashed, text} ->
        raise NotSettled, "#{@label}.settle: проход реактора упал, опрос остановлен:\n#{text}"
    end
  end

  # Реактор отвечает между проходами: долгий обработчик или транзакция теста держат ответ.
  # Предел вызова — остаток ожидания с запасом, чтобы провал был `NotSettled`, а не exit.
  defp request_report(reactor, timeout, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    GenServer.call(reactor, :report, remaining + @report_grace_ms)
  catch
    :exit, {:timeout, _call} ->
      raise NotSettled, "#{@label}.settle: реактор не ответил за #{timeout} мс — проход доставки не кончился"
  end

  defp check_settled(report, reactor, dead_letters, timeout, deadline) do
    cond do
      dead_letters == :fail and report.dead_letters != [] ->
        raise NotSettled, dead_letters_message(report.dead_letters)

      report.new == 0 and report.stuck == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise NotSettled, stuck_message(report, timeout)

      true ->
        Process.sleep(@settle_poll_ms)
        await_settled(reactor, dead_letters, timeout, deadline)
    end
  end

  defp dead_letters_message(dead_letters) do
    lines =
      Enum.map(dead_letters, fn %DeadLetter{} = dead ->
        line(dead.topic, dead.message, dead.subscriber, dead.attempts, dead.error) <> " reason=#{dead.reason}"
      end)

    Enum.join(["#{@label}.settle: мёртвые письма (разрешает dead_letters: :allow):" | lines], "\n")
  end

  defp stuck_message(report, timeout) do
    lines = Enum.map(report.stuck, &line(&1.topic, &1.message, &1.subscriber, &1.attempts, &1.error))
    title = "#{@label}.settle: доставка не затихла за #{timeout} мс, записей outbox :new — #{report.new}"
    Enum.join([title | lines], "\n")
  end

  defp line(topic, %Message{} = message, subscriber, attempts, error) do
    "  topic=#{topic} tag=#{Message.find_header(message, @tag_header)} " <>
      "event_id=#{Message.find_header(message, @event_id_header)} subscriber=#{inspect(subscriber)} " <>
      "attempts=#{attempts} error=#{error_text(error)}"
  end

  defp error_text(nil), do: "—"
  defp error_text(%Error{} = error), do: error.message

  # ===== реактор =====

  @doc false
  @spec check_subscribers!([keyword()], String.t()) :: :ok

  def check_subscribers!(subscribers, label) when is_list(subscribers) and is_binary(label) do
    _parsed = parse_subscribers!(subscribers, label)
    :ok
  end

  @doc false
  @spec report([keyword()]) :: report()

  def report(subscribers) when is_list(subscribers) do
    state = state()

    %{
      new: Map.get(Core.Config.outbox_repo().queue_counts(), :new, 0),
      stuck: Enum.flat_map(parse_subscribers!(subscribers, "#{inspect(__MODULE__)}.report/1"), &stuck(state, &1)),
      dead_letters: state.dead_letters
    }
  end

  # ---

  defp stuck(state, subscriber) do
    cursor = cursor(state, subscriber)

    case next_message(state, subscriber, cursor) do
      nil ->
        []

      %Message{} = message ->
        [
          %{
            topic: subscriber.topic,
            subscriber: subscriber.name,
            message: message,
            attempts: cursor.attempts,
            error: cursor.error
          }
        ]
    end
  end

  # ===== общее =====

  defp parse_subscribers!(subscribers, label) do
    [subscribers: valid] = Core.Options.validate!([subscribers: subscribers], @subscribers_schema, label)
    parsed = Enum.map(valid, &parse_subscriber/1)
    :ok = Core.Options.unique!(label, :name, "различные name подписчиков", Enum.map(parsed, & &1.name))
    parsed
  end

  defp parse_subscriber(subscriber) do
    step = Step.new!(subscriber)

    %{
      name: Keyword.fetch!(subscriber, :name),
      topic: step.topic,
      step: %{step | data: Keyword.get(subscriber, :subscribe_data)},
      max_attempts: Keyword.fetch!(subscriber, :max_attempts)
    }
  end

  defp cursor(state, subscriber), do: Map.get(state.cursors, subscriber.name, @cursor)

  defp next_message(state, subscriber, cursor),
    do: Enum.at(Map.get(state.journals, subscriber.topic, []), cursor.position)

  defp state, do: Process.get(@state_key, %{journals: %{}, cursors: %{}, dead_letters: []})
end
