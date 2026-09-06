defmodule Core.Otel.Messaging do
  @moduledoc """
  Span'ы обмена сообщениями по semantic conventions OpenTelemetry.

  Имена атрибутов и структура спанов взяты из раздела «Messaging spans»
  (снимок 2026-09; статус конвенций — **Development**). Спека прямо требует
  не менять версию конвенций молча, поэтому имена объявлены здесь константами
  и живут в одном месте: правка — это осознанный переход на новый снимок,
  а не редактирование строки на call site.

  Три операции цепочки:

  | Функция | `messaging.operation.type` | Span kind | Родитель |
  |---|---|---|---|
  | `create/4` | `create` | `:producer` | контекст из carrier (тот, кто создал сообщение) |
  | `send/5` | `send` | `:producer` | текущий контекст публикующего |
  | `process/5` | `process` | `:consumer` | creation context из carrier |

  `send/5` связан с сообщениями пачки **ссылками** (`links`), а не вложенностью:
  спека требует «The 'Send' span SHOULD always link to the creation context that
  was injected into a message». Вложенность здесь была бы неверна — сообщения
  пачки приходят из разных трейсов, и создание сообщения не происходит внутри
  его отправки.

  Родителем `process/5` берётся creation context сообщения: спека допускает это
  «exclusively for single messages scenarios», а подписчик Core обрабатывает
  ровно по одному сообщению за цикл и вне объемлющего span'а.
  """

  alias Core.Otel

  @attr_system "messaging.system"
  @attr_operation_type "messaging.operation.type"
  @attr_operation_name "messaging.operation.name"
  @attr_destination "messaging.destination.name"
  @attr_message_id "messaging.message.id"
  @attr_batch_count "messaging.batch.message_count"

  @create "create"
  @send "send"
  @process "process"

  @typedoc "Имя топика / очереди; `nil` — операция не привязана к одному назначению."
  @type destination :: String.t() | nil

  @typedoc "Идентификатор сообщения в брокере; `nil` — сообщение без ключа."
  @type message_id :: String.t() | nil

  @typedoc """
  Опции операции.

  - `system:` — `messaging.system` (`"rabbitmq"`, `"kafka"`); не задан — атрибут не ставится
  - `operation_name:` — `messaging.operation.name`; по умолчанию совпадает с типом операции
  - `attributes:` — собственные атрибуты вызывающего (вне пространства `messaging.*`)
  - `scope:` — модуль instrumentation scope (см. `Core.Otel`)
  """
  @type opts :: [
          system: String.t(),
          operation_name: String.t(),
          attributes: Otel.attributes(),
          scope: module()
        ]

  @doc """
  Отметить создание сообщения и записать контекст создания в carrier.

  Родитель — контекст из `carrier` (например `traceparent`, положенный командой
  в запись outbox). Возвращает обновлённый carrier — его получает сообщение —
  и контекст create-span'а для `links:` у `send/5`.
  """
  @spec create(Otel.carrier(), destination(), message_id(), opts()) ::
          {Otel.carrier(), Otel.span_ctx() | :undefined}

  def create(carrier, destination, message_id, opts \\ []) when is_map(carrier) do
    attributes =
      opts
      |> attributes(@create, destination)
      |> put_message_id(message_id)

    span_opts = span_opts(opts, :producer, attributes)

    Otel.with_span_from(carrier, name(@create, destination), span_opts, fn ->
      {Otel.inject(carrier), Otel.current_span()}
    end)
  end

  @doc """
  Выполнить `fun` — отправку пачки — в span'е `send`.

  `links` — контексты создания сообщений пачки (из `create/4`); `destination`
  задаётся, только когда у всей пачки он один.
  """
  @spec send(destination(), pos_integer(), [Otel.span_ctx()], opts(), (-> result)) :: result
        when result: var

  def send(destination, batch_count, links, opts, fun)
      when is_integer(batch_count) and batch_count > 0 and is_list(links) do
    attributes =
      opts
      |> attributes(@send, destination)
      |> Map.put(@attr_batch_count, batch_count)

    span_opts = [{:links, links} | span_opts(opts, :producer, attributes)]

    Otel.span(name(@send, destination), span_opts, fun)
  end

  @doc """
  Выполнить `fun` — обработку сообщения — в span'е `process`.

  Родитель — creation context из заголовков сообщения.
  """
  @spec process(Otel.carrier(), destination(), message_id(), opts(), (-> result)) :: result
        when result: var

  def process(carrier, destination, message_id, opts, fun) when is_map(carrier) do
    attributes =
      opts
      |> attributes(@process, destination)
      |> put_message_id(message_id)

    span_opts = span_opts(opts, :consumer, attributes)

    Otel.with_span_from(carrier, name(@process, destination), span_opts, fun)
  end

  # ---

  # Спека: `{messaging.operation.name} {destination}`; без известного назначения
  # остаётся одно имя операции — иначе в имя попал бы высококардинальный мусор.
  defp name(operation, nil), do: operation

  defp name(operation, destination), do: "#{operation} #{destination}"

  defp attributes(opts, operation, destination) do
    opts
    |> Keyword.get(:attributes, %{})
    |> Map.put(@attr_operation_type, operation)
    |> Map.put(@attr_operation_name, Keyword.get(opts, :operation_name, operation))
    |> put_optional(@attr_destination, destination)
    |> put_optional(@attr_system, Keyword.get(opts, :system))
  end

  defp put_message_id(attributes, message_id) do
    put_optional(attributes, @attr_message_id, message_id)
  end

  defp put_optional(attributes, _key, nil), do: attributes

  defp put_optional(attributes, key, value), do: Map.put(attributes, key, value)

  defp span_opts(opts, kind, attributes) do
    [kind: kind, attributes: attributes] ++ Keyword.take(opts, [:scope])
  end
end
