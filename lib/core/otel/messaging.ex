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

  use Core.Options

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

  @operation_opts_schema [
    system: [type: :string, doc: "`messaging.system` (`\"rabbitmq\"`, `\"kafka\"`); не задан — атрибут не ставится."],
    operation_name: [type: :string, doc: "`messaging.operation.name`; не задан — совпадает с типом операции."],
    attributes: [
      type: {:map, :string, :any},
      default: %{},
      doc: "Собственные атрибуты вызывающего (вне `messaging.*`)."
    ],
    scope: [type: :atom, doc: "Модуль instrumentation scope (`Core.Otel`)."]
  ]

  @doc """
  Отметить создание сообщения и записать контекст создания в carrier.

  Родитель — контекст из `carrier` (например `traceparent`, положенный командой
  в запись outbox). Возвращает обновлённый carrier — его получает сообщение —
  и контекст create-span'а для `links:` у `send/5`.
  """
  @opts_schema @operation_opts_schema
  @spec create(Otel.carrier(), destination(), message_id(), keyword()) ::
          {Otel.carrier(), Otel.span_ctx() | :undefined}

  def create(carrier, destination, message_id, opts \\ []) when is_map(carrier) do
    attributes =
      opts
      |> attributes(@create, destination)
      |> put_message_id(message_id)

    span_opts = span_opts(opts, :producer, attributes)

    Otel.with_span_from(
      carrier,
      name(@create, destination),
      fn -> {Otel.inject(carrier), Otel.current_span()} end,
      span_opts
    )
  end

  @doc """
  Выполнить `fun` — отправку пачки — в span'е `send`.

  `links` — контексты создания сообщений пачки (из `create/4`); `destination`
  задаётся, только когда у всей пачки он один.
  """
  @opts_schema @operation_opts_schema
  @spec send(destination(), pos_integer(), [Otel.span_ctx()], (-> result), keyword()) :: result
        when result: var

  def send(destination, batch_count, links, fun, opts \\ [])
      when is_integer(batch_count) and batch_count > 0 and is_list(links) do
    attributes =
      opts
      |> attributes(@send, destination)
      |> Map.put(@attr_batch_count, batch_count)

    span_opts = [{:links, links} | span_opts(opts, :producer, attributes)]

    Otel.span(name(@send, destination), fun, span_opts)
  end

  @doc """
  Выполнить `fun` — обработку сообщения — в span'е `process`.

  Родитель — creation context из заголовков сообщения.
  """
  @opts_schema @operation_opts_schema
  @spec process(Otel.carrier(), destination(), message_id(), (-> result), keyword()) :: result
        when result: var

  def process(carrier, destination, message_id, fun, opts \\ []) when is_map(carrier) do
    attributes =
      opts
      |> attributes(@process, destination)
      |> put_message_id(message_id)

    span_opts = span_opts(opts, :consumer, attributes)

    Otel.with_span_from(carrier, name(@process, destination), fun, span_opts)
  end

  # ---

  # Спека: `{messaging.operation.name} {destination}`; без известного назначения
  # остаётся одно имя операции — иначе в имя попал бы высококардинальный мусор.
  defp name(operation, nil), do: operation
  defp name(operation, destination), do: "#{operation} #{destination}"

  defp attributes(opts, operation, destination) do
    opts
    |> Keyword.fetch!(:attributes)
    |> Map.put(@attr_operation_type, operation)
    |> Map.put(@attr_operation_name, Keyword.get(opts, :operation_name) || operation)
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
