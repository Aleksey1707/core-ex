defmodule Core.Mq.Dlq do
  @moduledoc """
  DLQ подписчиков в Postgres: отклонённые сообщения — строки таблицы `mq_dlq` БД потребителя
  (`Core.Mq.Dlq.Migration`), а не топик брокера.

  Топики внешнего источника принадлежат не потребителю: завести рядом `<topic>.dlq` он не может,
  а разбирать отклонённое удобнее запросом, чем чтением топика.

  - `Core.Mq.Dlq.Writer` — `Mq.Writer` в таблицу; подключается `dlq_writer:` подписчика
    (`Core.PubSub.MqSubscriberReliable`) и пишет строку `dead` с топиком, ключом, заголовками,
    телом, позицией источника, причиной и временем выброса.
  - `requeue/2` — команда оператора: `dead` → `requeued`. Точки входа —
    `mix mq.dlq.requeue` и `Core.Mq.Dlq.Release.requeue/2` в задаче релиза.
  - `Core.Mq.Dlq.Reader` — `Mq.ReaderReliable` из таблицы: отдаёт `requeued`-записи топика, а
    `commit` помечает запись `processed`, не удаляя её. Подписчик с тем же обработчиком, что у
    исходного топика, поверх него перечитывает возвращённое.

  Сообщение переживает выброс и перечитывание без искажения (ADR-0032): tombstone
  (`body: nil`), байтовый ключ, `key: nil`, значения заголовков не в UTF-8 и позиция источника.

  ## Жизненный цикл записи

  | `status` | Что значит |
  |---|---|
  | `dead` | сообщение выброшено подписчиком и ждёт оператора |
  | `requeued` | оператор вернул его в обработку; его читает `Core.Mq.Dlq.Reader` |
  | `processed` | перечитано и закоммичено; строка остаётся для разбора |

  Повторный отказ перечитанного сообщения пишет новую строку `dead` — через `dlq_writer:`
  подписчика перечитывания, — а прежняя становится `processed`. Порядок относительно уже
  обработанных сообщений исходного топика не восстанавливается. Строки `processed` библиотека не
  удаляет: их чистит оператор.

  Разбор запросом:

      SELECT id, topic, reason, error, convert_from(body, 'UTF8') AS body, created_at
      FROM mq_dlq WHERE status = 'dead' ORDER BY id;
  """

  alias Core.Mq

  @requeue_sql "UPDATE mq_dlq SET status = 'requeued', requeued_at = clock_timestamp(), " <>
                 "lease_id = NULL, locked_until = NULL WHERE status = 'dead'"

  @counts_sql "SELECT subscriber_name, topic, status, count(*) FROM mq_dlq GROUP BY subscriber_name, topic, status"

  @statuses ~w(dead requeued processed)

  @typedoc "Цель `requeue/2`: все записи, записи топика или записи по `id`."
  @type target :: :all | {:topic, Mq.Topic.t()} | [pos_integer()]

  @typedoc "Статус записи DLQ."
  @type status :: String.t()

  @typedoc "Число записей пары подписчик-топик в статусе."
  @type count :: %{subscriber: String.t(), topic: String.t(), status: status(), count: non_neg_integer()}

  # ===== команда оператора =====

  @doc """
  Вернуть записи `dead` в обработку; результат — число возвращённых.

  Записи в другом статусе не трогаются: `id` уже `requeued` или `processed` записи в счёт не
  входит.
  """
  @spec requeue(Ecto.Repo.t(), target()) :: non_neg_integer()

  def requeue(repo, :all) when is_atom(repo), do: run_requeue(repo, "", [])

  def requeue(repo, {:topic, %Mq.Topic{} = topic}) when is_atom(repo),
    do: run_requeue(repo, " AND topic = $1", [Mq.Topic.value(topic)])

  def requeue(repo, [_ | _] = ids) when is_atom(repo), do: run_requeue(repo, " AND id = ANY($1)", [ids])

  # ---

  defp run_requeue(repo, filter, params) do
    %{num_rows: count} = Ecto.Adapters.SQL.query!(repo, @requeue_sql <> filter, params)
    count
  end

  # ===== метрики =====

  @doc """
  Число записей по подписчику, топику и статусу.

  Каждая пара подписчик-топик отдаётся со всеми статусами, отсутствующий — с нулём: gauge
  статуса, из которого записи ушли, обнуляется, а не застывает на последнем значении.
  """
  @spec counts(Ecto.Repo.t()) :: [count()]

  def counts(repo) when is_atom(repo) do
    %{rows: rows} = Ecto.Adapters.SQL.query!(repo, @counts_sql, [])
    found = Map.new(rows, fn [subscriber, topic, status, count] -> {{subscriber, topic, status}, count} end)

    pairs = Enum.uniq(for [subscriber, topic | _] <- rows, do: {subscriber, topic})

    for {subscriber, topic} <- pairs, status <- @statuses do
      %{subscriber: subscriber, topic: topic, status: status, count: Map.get(found, {subscriber, topic, status}, 0)}
    end
  end
end
