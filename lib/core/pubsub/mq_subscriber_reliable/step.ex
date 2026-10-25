defmodule Core.PubSub.MqSubscriberReliable.Step do
  @moduledoc false

  # Шаг обработки одного сообщения подписчиком: `filter` → span `process` → `from_message` →
  # контекст от `context_factory` с основанием из заголовка `operation_id` → `on_message`,
  # исключение обработчика — `{:error, %Error{}}`.
  # Чтение, `commit`, счёт попыток, backoff, DLQ и telemetry цикла — у вызывающего: исход
  # он получает в `fun`, внутри span'а обработки, и может дополнить span (причина выброса в DLQ).
  # Ключи шага — `schema/0`: вызывающий включает её в свою схему, `new!/2` берёт и проверяет только их.

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Mq
  alias Core.Mq.Message
  alias Core.Options
  alias Core.Otel
  alias Core.PubSub
  alias Core.Repo

  require Logger
  require Error

  @attr_attempt "core.pubsub.attempt"

  @schema [
    topic: [
      type: {:custom, Core.Helper.StartOpts, :binary, []},
      type_doc: "`t:String.t/0`",
      default: "unknown",
      doc: "Топик: метка метрик и span'а обработки."
    ],
    filter: [
      type: {:fun, 1},
      default: &Core.PubSub.MqSubscriberReliable.Step.accept_all/1,
      doc: "Предикат по сырому `Core.Mq.Message` до `from_message`; `false` — сообщение отфильтровано."
    ],
    from_message: [
      type: {:fun, 1},
      required: true,
      doc: "Декодер сырого сообщения, результат — `t:Core.PubSub.decode_result/1`."
    ],
    on_message: [
      type: {:fun, 3},
      required: true,
      doc: "Обработчик: сообщение, данные подписки и контекст; результат — `t:Core.PubSub.handler_result/0`."
    ],
    context_factory: [
      type: {:fun, 0},
      default: &Core.Context.new/0,
      doc: "Фабрика `Core.Context`; вызывается на каждое сообщение."
    ]
  ]
  @compiled NimbleOptions.new!(@schema)

  @enforce_keys ~w(topic filter from_message on_message context_factory data)a
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          topic: String.t(),
          filter: (Message.t() -> boolean()),
          from_message: (Message.t() -> PubSub.decode_result(term())),
          on_message: (term(), term(), Context.t() -> PubSub.handler_result()),
          context_factory: (-> Context.t()),
          data: term()
        }

  @typedoc """
  Исход шага: обработано (`:ok` и `{:skip, _}` обработчика), отфильтровано, повтор с ошибкой,
  отказ без повторов.
  """
  @type outcome :: :processed | :filtered | {:retry, Error.t()} | {:reject, Error.t()}

  # ===== опции =====

  @doc false
  @spec schema() :: keyword()

  def schema, do: @schema

  @doc false
  @spec new!(String.t(), keyword()) :: t()

  def new!(label, opts) when is_binary(label) and is_list(opts) do
    valid = Options.__validate__!(Keyword.take(opts, Keyword.keys(@schema)), @compiled, label)

    struct!(__MODULE__, [data: nil] ++ valid)
  end

  @doc false
  @spec accept_all(Message.t()) :: true

  def accept_all(%Message{}), do: true

  # ===== обработка =====

  @doc false
  @spec run(Message.t(), t(), pos_integer()) :: outcome()
  @spec run(Message.t(), t(), pos_integer(), (outcome() -> a)) :: a when a: term()

  def run(%Message{} = raw, %__MODULE__{} = step, attempt, fun \\ &Function.identity/1)
      when is_integer(attempt) and attempt > 0 and is_function(fun, 1) do
    case safe_filter(step, raw) do
      true ->
        process(step, raw, attempt, fun)

      false ->
        fun.(:filtered)

      {:error, %Error{} = error} ->
        Logger.warning("pubsub reliable filter: #{error.message}")
        fun.({:retry, error})

      other ->
        Logger.warning("pubsub reliable filter: неожиданный результат #{inspect(other)}")
        fun.({:retry, unexpected_result_error(:filter, other)})
    end
  end

  # ---

  # Фильтр стоит до span'а: у внешнего топика без `traceparent` каждое отвергнутое сообщение
  # открывало бы свой корневой трейс.
  defp safe_filter(step, raw) do
    step.filter.(raw)
  rescue
    exception -> {:error, handler_crash_error(:filter, exception, __STACKTRACE__)}
  end

  # Span покрывает и декод, и обработчик: родитель берётся из заголовков сообщения
  # (контекст создания записи outbox), поэтому обработка продолжает трейс команды,
  # а не начинает свой. Номер попытки — собственный атрибут подписчика: в semconv
  # его нет, а в пространство `messaging.*` чужие имена класть нельзя.
  defp process(step, raw, attempt, fun) do
    Otel.Messaging.process(
      raw.headers,
      step.topic,
      message_id(raw),
      fn -> decode(step, raw, fun) end,
      attributes: %{@attr_attempt => attempt}
    )
  end

  # Ключ чужого топика — байты (ADR-0032): не-UTF-8 атрибутом span'а экспортёр не отдаст.
  defp message_id(%Message{key: nil}), do: nil

  defp message_id(%Message{key: key}) do
    value = Mq.Key.value(key)

    if String.valid?(value), do: value
  end

  defp decode(step, raw, fun) do
    case safe_from_message(step, raw) do
      {:ok, message} ->
        dispatch(step, raw.headers, message, fun)

      {:error, %Error{} = error} ->
        Logger.warning("pubsub reliable from_message: #{error.message}")
        Otel.record_error(error)
        fun.({:retry, error})

      {:reject, %Error{} = error} ->
        Otel.record_error(error)
        fun.({:reject, error})

      other ->
        Logger.warning("pubsub reliable from_message: неожиданный результат #{inspect(other)}")
        error = unexpected_result_error(:from_message, other)
        Otel.record_error(error)
        fun.({:retry, error})
    end
  end

  defp safe_from_message(step, raw) do
    step.from_message.(raw)
  rescue
    exception -> {:error, handler_crash_error(:from_message, exception, __STACKTRACE__)}
  end

  # Контекст создаётся на сообщение и уничтожается после него: `Repo.Sc` держит эталоны
  # в ETS, и один контекст на весь uptime подписчика рос бы неограниченно, отдавая
  # write-репозиториям устаревшие эталоны.
  defp dispatch(step, headers, message, fun) do
    context = with_basis(step.context_factory.(), headers)

    try do
      fun.(call_handler(step, message, context))
    after
      Repo.Sc.delete(context)
    end
  end

  # Основание — операция события, на которое реагирует обработчик (ADR-0081): события,
  # записанные в `on_message`, получают его как `basis_id`. Сообщение без заголовка или с
  # нечитаемым значением (внешний источник, старая запись outbox) обрабатывается без основания.
  defp with_basis(context, %{"operation_id" => value}) when is_binary(value) do
    case Config.codec().load(Es.Event.OperationID, value) do
      {:ok, %Es.Event.OperationID{} = basis} ->
        Context.Basis.put(context, basis)

      {:error, _reason} ->
        Logger.warning("pubsub reliable basis: заголовок operation_id не читается: value=#{inspect(value)}")
        context
    end
  end

  defp with_basis(context, _headers), do: context

  defp call_handler(step, message, context) do
    case safe_on_message(step, message, context) do
      :ok ->
        :processed

      {:skip, _reason} ->
        :processed

      {:error, %Error{} = error} ->
        Logger.warning("pubsub reliable on_message: #{error.message}")
        Otel.record_error(error)
        {:retry, error}

      {:reject, %Error{} = error} ->
        Otel.record_error(error)
        {:reject, error}

      other ->
        Logger.warning("pubsub reliable on_message: неожиданный результат #{inspect(other)}")
        error = unexpected_result_error(:on_message, other)
        Otel.record_error(error)
        {:retry, error}
    end
  end

  defp safe_on_message(step, message, context) do
    step.on_message.(message, step.data, context)
  rescue
    exception -> {:error, handler_crash_error(:on_message, exception, __STACKTRACE__)}
  end

  defp handler_crash_error(handler, exception, stacktrace) do
    Error.app(
      code: :handler_crashed,
      ns: :pubsub,
      message: "#{handler} завершился исключением",
      detail: %{exception: exception, stacktrace: stacktrace}
    )
  end

  defp unexpected_result_error(handler, other) do
    Error.app(
      code: :unexpected_handler_result,
      ns: :pubsub,
      message: "#{handler} вернул неожиданный результат",
      detail: other
    )
  end
end
