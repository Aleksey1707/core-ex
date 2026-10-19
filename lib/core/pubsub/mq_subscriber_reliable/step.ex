defmodule Core.PubSub.MqSubscriberReliable.Step do
  @moduledoc false

  # Шаг обработки одного сообщения подписчиком: `filter` → span `process` → `from_message` →
  # контекст от `context_factory` → `on_message`, исключение обработчика — `{:error, %Error{}}`.
  # Чтение, `commit`, счёт попыток, backoff, DLQ и telemetry цикла — у вызывающего: исход
  # он получает в `fun`, внутри span'а обработки, и может дополнить span (причина выброса в DLQ).

  alias Core.Context
  alias Core.Error
  alias Core.Helper.StartOpts
  alias Core.Mq
  alias Core.Mq.Message
  alias Core.Otel
  alias Core.PubSub
  alias Core.Repo

  require Logger
  require Error

  @attr_attempt "core.pubsub.attempt"

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
  @spec new!(String.t(), keyword()) :: t()

  def new!(label, opts) when is_binary(label) and is_list(opts) do
    %__MODULE__{
      topic: StartOpts.binary!(label, opts, :topic, "unknown"),
      filter: StartOpts.fun!(label, opts, :filter, 1, &accept_all/1),
      from_message: StartOpts.fun!(label, opts, :from_message, 1),
      on_message: StartOpts.fun!(label, opts, :on_message, 3),
      context_factory: StartOpts.fun!(label, opts, :context_factory, 0, &Context.new/0),
      data: nil
    }
  end

  # ---

  defp accept_all(%Message{}), do: true

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
    opts = [attributes: %{@attr_attempt => attempt}]

    Otel.Messaging.process(raw.headers, step.topic, message_id(raw), opts, fn ->
      decode(step, raw, fun)
    end)
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
        dispatch(step, message, fun)

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
  defp dispatch(step, message, fun) do
    context = step.context_factory.()

    try do
      fun.(call_handler(step, message, context))
    after
      Repo.Sc.delete(context)
    end
  end

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
