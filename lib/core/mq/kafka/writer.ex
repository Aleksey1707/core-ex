# Kafka-клиент объявлен в библиотеке `optional: true`: адаптер компилируется только
# у тех потребителей, которые добавили клиента себе в `deps`. Без него модуля
# просто нет — вместо ошибки компиляции библиотеки вызов даст UndefinedFunctionError.
if Code.ensure_loaded?(:brod) do
  defmodule Core.Mq.Kafka.Writer do
    @moduledoc """
    `Mq.Writer` для Kafka через клиент `:brod`.

    Handle writer'а — id клиента `:brod` (атом): клиента стартует app-слой в своём дереве с
    `auto_start_producers: true`; собственного состояния нет.
    Публикация строго по порядку (`:brod.produce_sync/5`), стоп на первой ошибке.

    Сообщение пишется нативно: тело — значение записи, `Mq.Key` — байты ключа, заголовки —
    заголовки записи. Партиция ключа — `Core.Mq.Kafka.Partitioner` (murmur2, как у
    `DefaultPartitioner` Kafka), без ключа — случайная.

    `body: ""` — отказ до отправки: `:brod` пишет пустое значение как null, и сообщение стало бы
    tombstone, молча удаляющим ключ компактного топика (ADR-0034).

    Идемпотентного продюсера у `:brod` нет: повтор отправки внутри клиента может задвоить
    запись, подписчик обязан быть идемпотентным.

    `detail` ошибки `:kafka_publish_failed` — атом причины (`:empty_body`,
    `:unknown_topic_or_partition`, `:client_down`, код брокера из метаданных топика),
    `{:error_code, code}` отказа брокера на запись либо текст: `:brod` отдаёт сбои чем придётся,
    и нормализация сводит их к этим трём формам, чтобы на call site было что разбирать.
    """

    @behaviour Core.Mq.Writer

    alias Core.Error
    alias Core.Helper.Transact
    alias Core.Mq
    alias Core.Mq.Kafka.Partitioner
    alias Core.Mq.Message
    alias Core.Telemetry

    require Error

    @doc "Опубликовать сообщение."
    @spec put(atom(), Message.t()) :: :ok | {:error, Error.t()}

    @impl true
    def put(client, %Message{} = message) when is_atom(client) do
      case put_many(client, [message]) do
        :ok -> :ok
        {:error, _index, %Error{} = error} -> {:error, error}
      end
    end

    @doc "Опубликовать сообщения по порядку; стоп на первой ошибке."
    @spec put_many(atom(), [Message.t()]) :: :ok | {:error, non_neg_integer(), Error.t()}

    @impl true
    def put_many(client, messages) when is_atom(client) and is_list(messages) do
      :ok = Transact.warn_in_transaction("публикация пачки в kafka")

      messages
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {message, index}, :ok ->
        case put_one(client, message) do
          :ok -> {:cont, :ok}
          {:error, %Error{} = error} -> {:halt, {:error, index, error}}
        end
      end)
    end

    # ---

    defp put_one(_client, %Message{body: ""}), do: kafka_error(:empty_body)

    defp put_one(client, %Message{} = message) do
      topic = Mq.Topic.value(message.topic)
      start = System.monotonic_time()

      case produce(client, topic, message) do
        :ok ->
          emit_publish(start, :ok, topic)
          :ok

        {:error, reason} ->
          emit_publish(start, :error, topic)
          kafka_error(reason)
      end
    end

    defp emit_publish(start, result, topic) do
      :telemetry.execute(
        Telemetry.event([:mq, :kafka, :publish]),
        %{duration: System.monotonic_time() - start, count: 1},
        %{result: result, topic: topic}
      )
    end

    # Число партиций — `get_partitions_count_safe/2`: партиционер-функция в `produce_sync/5`
    # спрашивает метаданные с автосозданием, и опечатка в топике на кластере с
    # `auto.create.topics.enable` создала бы топик вместо ошибки. Пустой ключ `:brod` пишет как
    # null — сообщение без ключа. Непойманное исключение клиента унесло бы вызывающего
    # (`Outbox.Poller`), поэтому ловится любое исключение.
    defp produce(client, topic, %Message{} = message) do
      key = key(message.key)
      value = %{value: message.body, headers: Map.to_list(message.headers)}

      with {:ok, count} <- :brod.get_partitions_count_safe(client, topic),
           :ok <- :brod.produce_sync(client, topic, Partitioner.partition(key, count), key || "", value) do
        :ok
      else
        {:error, reason} -> {:error, normalize_brod_reason(reason)}
      end
    rescue
      exception -> {:error, Exception.message(exception)}
    end

    defp key(nil), do: nil
    defp key(%Mq.Key{} = key), do: Mq.Key.value(key)

    # Отказ брокера на запись роняет продюсера партиции: `:not_retriable` — сразу,
    # `:reached_max_retries` — после исчерпания повторов.
    defp normalize_brod_reason({:producer_down, {exit, {:produce_response_error, _, _, _, code}}})
         when exit in [:not_retriable, :reached_max_retries],
         do: {:error_code, code}

    defp normalize_brod_reason(reason) when is_atom(reason) or is_binary(reason), do: reason

    defp normalize_brod_reason(reason), do: inspect(reason)

    defp kafka_error(reason) do
      {:error,
       Error.app(
         code: :kafka_publish_failed,
         ns: :mq,
         message: "Не удалось опубликовать сообщение в Kafka",
         detail: reason
       )}
    end
  end
end
