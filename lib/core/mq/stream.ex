defmodule Core.Mq.Stream do
  @moduledoc """
  Адаптеры RabbitMQ Stream для `Core.Mq`.

  Клиент `:rabbitmq_stream` объявлен в библиотеке `optional: true`
  (`10-architecture.md`): `Stream.Connection` и `Stream.Reader` компилируются только
  у потребителей, добавивших его в свои `deps`.
  """

  alias Core.Error
  alias Core.Mq
  alias Core.Result

  require Error
  require Logger

  @max_id 255

  @doc """
  Проверить, что клиент `:rabbitmq_stream` присутствует и адаптер собран с ним.

  Звать из `start/2` приложения-потребителя, если оно поднимает `Stream.Connection` —
  тогда проблема всплывает понятной ошибкой при старте, а не `UndefinedFunctionError`
  где-то в глубине supervisor-дерева на первом вызове (по образцу
  `Core.Security.Secret.ensure_configured!/0`). Различает два случая: клиента нет
  в сборке вовсе, и клиент есть, но библиотека была собрана без него и не пересобрана.
  """
  @spec ensure_available!() :: :ok

  def ensure_available! do
    Mq.Client.ensure_available!(
      label: "Core.Mq.Stream",
      client: RabbitMQStream.Connection,
      adapter: Core.Mq.Stream.Connection,
      dep: :rabbitmq_stream,
      requirement: "~> 0.4"
    )
  end

  # Номер подписки и producer'а в кадре протокола — один байт, а клиент `:rabbitmq_stream`
  # выдаёт их счётчиком на процесс соединения, не переиспользуя и не сбрасывая при
  # переподключении. С 256-го номера брокер получает его по модулю 256: данные подписки
  # уходят чужому номеру и клиент их молча выбрасывает. Сбрасывает счётчик только новый
  # процесс соединения — поэтому соединение, выдавшее такой номер, останавливается, его
  # поднимает супервизор, а reader и writer повторяют своим обычным путём повтора.
  @doc false
  @spec accept_id_or_restart(pid() | nil, :subscription | :producer, non_neg_integer()) :: Result.t(non_neg_integer())

  def accept_id_or_restart(_conn_pid, _kind, id) when id <= @max_id, do: {:ok, id}

  def accept_id_or_restart(conn_pid, kind, id) do
    Logger.warning("stream: номера соединения исчерпаны, перезапуск соединения: kind=#{kind} id=#{id}")
    stop_connection(conn_pid)

    {:error,
     Error.app(
       code: :connection_ids_exhausted,
       ns: :mq,
       message: "Номера соединения RabbitMQ Stream исчерпаны, соединение перезапущено",
       detail: %{kind: kind, id: id}
     )}
  end

  # ---

  defp stop_connection(nil), do: :ok

  defp stop_connection(pid) do
    GenServer.stop(pid, {:shutdown, :ids_exhausted}, 5_000)
  catch
    :exit, _reason -> :ok
  end
end
