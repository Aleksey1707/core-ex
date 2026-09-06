defmodule Core.Es.Outbox do
  @moduledoc """
  Билдер модуля `<Aggregate>.Outbox` — маппинга событий агрегата в `Outbox.Record`.

      use Core.Es.Outbox,
        topic: "roles",
        event: MyApp.Domain.<BC>.Common.Role.Event

  Генерирует `from_events/1` и `from_event/1`. Wire-payload — конверт события целиком
  (`codec.dump(event)`, формат — `Core.Es.Event.Codec`); топик, ключ, имя и заголовки
  (`name` / `aggr_id` / `event_id`) читаются из того же конверта через
  `Core.Es.Event.Codec.to_fields/1` — второго источника wire-имени события нет.

  К заголовкам добавляется `traceparent` текущего трейса (`Core.Otel.inject/1`):
  запись публикуется поллером в другом процессе и через секунду, поэтому контекст
  команды переносится в строке outbox, а не в process dictionary.

  ## Opts

  - `topic:` — имя топика (строка); валидируется `Outbox.Topic` на этапе компиляции
  - `event:` — объединяющий модуль событий агрегата (нужен для `@type event`)
  - `codec:` — entity-фасад Codec; по умолчанию резолвится в рантайме
    через `Core.Config.codec()`

  Макрос занимает в вызывающем модуле имена `@es_topic`, `@es_event` и приватную
  `es_codec/0`.
  """

  alias Core.Helper
  alias Core.Outbox

  @label "Es.Outbox"
  @required_keys ~w(topic event)a
  @optional_keys ~w(codec)a

  @doc "Объявить маппер событий агрегата в записи outbox."
  defmacro __using__(opts) do
    {topic, event, codec} =
      opts
      |> Macro.expand_literals(__CALLER__)
      |> validate_opts!()

    quote do
      @es_topic unquote(Macro.escape(topic))
      @es_event unquote(event)

      @typedoc "Событие агрегата, отображаемое в запись outbox."
      @type event :: unquote(event).t()

      @doc "Список событий → список записей outbox."
      @spec from_events([event()]) ::
              {:ok, [Core.Outbox.Record.t()]} | {:error, Core.Error.t()}

      def from_events(events) when is_list(events) do
        Core.Result.traverse(events, &from_event/1)
      end

      @doc "Одно событие → запись outbox."
      @spec from_event(event()) ::
              {:ok, Core.Outbox.Record.t()} | {:error, Core.Error.t()}

      def from_event(event) do
        payload = es_codec().dump(event)
        fields = Core.Es.Event.Codec.to_fields(payload)

        with {:ok, key} <- Core.Outbox.Key.new(fields.aggregate_id),
             {:ok, name} <- Core.Outbox.Name.new(fields.type),
             {:ok, created_at} <- Core.Outbox.CreatedAt.now() do
          Core.Outbox.Record.new(@es_topic, key, name, payload, headers(fields), created_at)
        end
      end

      defp es_codec, do: unquote(codec)

      defp headers(fields) do
        Core.Otel.inject(%{
          "name" => fields.type,
          "aggr_id" => fields.aggregate_id,
          "event_id" => fields.id
        })
      end
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
      Helper.Opts.module!(opts, :event, @label),
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
end
