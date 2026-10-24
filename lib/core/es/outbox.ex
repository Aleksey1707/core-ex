defmodule Core.Es.Outbox do
  @moduledoc """
  Билдер модуля `<Aggregate>.Outbox` — маппинга событий агрегата в `Outbox.Record`.

      use Core.Es.Outbox,
        topic: "roles",
        family: MyApp.Domain.<BC>.Role.Event

  Генерирует `topic/0`, `from_events/1`, `from_event/1` и интроспекцию `__es_event__/0` — семейство
  (сверка с семейством кодека в `Core.Repo.Pg.StateStored` и `Core.Es.Aggregate.Repo.Pg`).
  Wire-payload — конверт события целиком (`codec.dump(event)`, формат — `Core.Es.Event.Codec`);
  топик, ключ, имя и заголовки (`name` / `aggr_id` / `event_id`) читаются из того же конверта через
  `Core.Es.Event.Codec.to_fields/1` — второго источника wire-имени события нет. Операция события
  (`Core.Es.Operation`) добавляется заголовком `operation_id`, если она есть: по нему подписчик
  получает основание.

  К заголовкам добавляется `traceparent` текущего трейса (`Core.Otel.inject/1`):
  запись публикуется поллером в другом процессе и через секунду, поэтому контекст
  команды переносится в строке outbox, а не в process dictionary.

  ## Opts

  - `topic:` — имя топика (строка); валидируется `Outbox.Topic` на этапе компиляции, его отдаёт
    `topic/0`
  - `family:` — семейство событий агрегата (`use Core.Es.Event.Family`); `@type event` — его `t()`.
    Event-sourced и state-stored агрегат объявляют его одинаково
  - `codec:` — entity-фасад Codec; по умолчанию резолвится в рантайме
    через `Core.Config.codec()`

  Запись из конверта без `traceparent` собирает `record/2` — её же зовёт переопубликация окна
  (`Core.Outbox.Release.republish_since/2`), поэтому пересобранная запись совпадает с записанной.

  Макрос занимает в вызывающем модуле имена `@es_topic`, `@es_event` и приватную `es_codec/0`.
  """

  alias Core.Es
  alias Core.Helper
  alias Core.Outbox
  alias Core.Result

  @label "Es.Outbox"
  @required_keys ~w(topic family)a
  @optional_keys ~w(codec)a

  # ===== билдер =====

  @doc "Объявить маппер событий агрегата в записи outbox."
  defmacro __using__(opts) do
    {topic, family, codec} =
      opts
      |> Macro.expand_literals(__CALLER__)
      |> validate_opts!()

    quote do
      @es_topic unquote(Macro.escape(topic))
      @es_event unquote(family)

      @typedoc "Событие агрегата, отображаемое в запись outbox."
      @type event :: unquote(family).t()

      @doc false
      @spec __es_event__() :: module()

      def __es_event__, do: @es_event

      @doc "Топик, в который уходят события агрегата; подписчик берёт его отсюда, а не литералом."
      @spec topic() :: String.t()

      def topic, do: unquote(Outbox.Topic.value(topic))

      @doc "Список событий → список записей outbox."
      @spec from_events([event()]) ::
              Core.Result.t([Core.Outbox.Record.t()])

      def from_events(events) when is_list(events) do
        Core.Result.traverse(events, &from_event/1)
      end

      @doc "Одно событие → запись outbox."
      @spec from_event(event()) ::
              Core.Result.t(Core.Outbox.Record.t())

      unquote(
        quote generated: true do
          def from_event(event) do
            case Core.Es.Outbox.record(@es_topic, es_codec().dump(event)) do
              {:ok, %Core.Outbox.Record{} = record} -> {:ok, %{record | headers: Core.Otel.inject(record.headers)}}
              {:error, reason} -> {:error, reason}
            end
          end
        end
      )

      defp es_codec, do: unquote(codec)
    end
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  # ---

  defp validate_opts!(opts) do
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)

    {
      validate_topic!(opts),
      Helper.Opts.module!(opts, :family, @label),
      Helper.Opts.module_or_config!(opts, :codec, :codec, @label)
    }
  end

  defp validate_topic!(opts) do
    topic = Helper.Opts.binary!(opts, :topic, @label)

    case Outbox.Topic.new(topic) do
      {:ok, topic} -> topic
      {:error, error} -> raise CompileError, description: "#{@label}: topic: #{error}"
    end
  end

  # ===== запись =====

  @doc false
  @spec record(Outbox.Topic.t(), Es.Event.Codec.wire()) :: Result.t(Outbox.Record.t())

  def record(%Outbox.Topic{} = topic, envelope) when is_map(envelope) do
    fields = Es.Event.Codec.to_fields(envelope)

    with {:ok, key} <- Outbox.Key.new(fields.aggregate_id),
         {:ok, name} <- Outbox.Name.new(fields.type),
         do: Outbox.Record.new(topic, key, name, envelope, headers(fields))
  end

  # ---

  defp headers(%{operation_id: nil} = fields), do: event_headers(fields)
  defp headers(fields), do: Map.put(event_headers(fields), "operation_id", fields.operation_id)

  defp event_headers(fields), do: %{"name" => fields.type, "aggr_id" => fields.aggregate_id, "event_id" => fields.id}
end
