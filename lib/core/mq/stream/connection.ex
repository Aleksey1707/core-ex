# Клиент rabbitmq stream объявлен в библиотеке `optional: true`: адаптер компилируется только
# у тех потребителей, которые добавили клиента себе в `deps`. Без него модуля
# просто нет — вместо ошибки компиляции библиотеки вызов даст UndefinedFunctionError.
if Code.ensure_loaded?(RabbitMQStream.Connection) do
  defmodule Core.Mq.Stream.Connection do
    @moduledoc """
    OTP-подключение к RabbitMQ Stream.
    """

    use RabbitMQStream.Connection

    @doc """
    Последний подтверждённый `publishing_id` для producer reference на топике.

    Обёртка `query_producer_sequence/2`, которую генерирует `use RabbitMQStream.Connection`,
    переставляет аргументы: форвардит `(reference, stream)` в функцию, объявленную как
    `(stream, reference)`. Запрос уходит на несуществующий stream и всегда отдаёт 0, из-за
    чего после рестарта writer публикует с уже использованных publishing_id, а брокер их
    молча отбрасывает по дедупликации. Зовём библиотечную функцию напрямую.
    """
    @spec producer_sequence(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}

    def producer_sequence(stream_name, producer_reference)
        when is_binary(stream_name) and is_binary(producer_reference) do
      RabbitMQStream.Connection.query_producer_sequence(
        __MODULE__,
        stream_name,
        producer_reference
      )
    end
  end
end
