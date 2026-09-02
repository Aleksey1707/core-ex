defmodule Core.Es.Outbox do
  @moduledoc """
  Билдер модуля `<Aggregate>.Outbox` — маппинга событий агрегата в `Outbox.Record`.

      use Core.Es.Outbox,
        topic: "roles",
        event: MyApp.Domain.<BC>.Common.Role.Event

  Генерирует `from_events/1` и `from_event/1`. Wire-payload — envelope события
  (`event_id`, `type`, `payload`, `aggregate_id`, `aggregate_version`, `at`, `by`),
  заголовки — `name` / `aggr_id` / `event_id`.

  ## Opts

  - `topic:` — имя топика (строка); валидируется `Outbox.Topic` на этапе компиляции
  - `event:` — объединяющий модуль событий агрегата (должен экспортировать `name/1`)
  - `codec:` — entity-фасад Codec; по умолчанию `Core.Config.codec()`

  Макрос занимает в вызывающем модуле имена `@es_topic`, `@es_event`, `@es_codec`.
  """

  alias Core.Config
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
      @es_codec unquote(codec)

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
        aggregate_id = @es_codec.dump(event.aggregate_id)
        event_id = @es_codec.dump(event.id)
        event_name = @es_event.name(event)

        with {:ok, key} <- Core.Outbox.Key.new(aggregate_id),
             {:ok, name} <- Core.Outbox.Name.new(event_name),
             {:ok, created_at} <- Core.Outbox.CreatedAt.now() do
          Core.Outbox.Record.new(
            @es_topic,
            key,
            name,
            wire_payload(event, aggregate_id, event_id),
            headers(event_name, aggregate_id, event_id),
            created_at
          )
        end
      end

      defp wire_payload(event, aggregate_id, event_id) do
        {type, payload} = @es_codec.dump(event)

        %{
          "event_id" => event_id,
          "type" => type,
          "payload" => payload,
          "aggregate_id" => aggregate_id,
          "aggregate_version" => Core.Version.value(event.aggregate_version),
          "at" => @es_codec.dump(event.at),
          "by" => @es_codec.dump(event.by)
        }
      end

      defp headers(event_name, aggregate_id, event_id) do
        %{
          "name" => event_name,
          "aggr_id" => aggregate_id,
          "event_id" => event_id
        }
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
      Helper.Opts.module!(opts, :event, @label, exports: [name: 1]),
      Keyword.get(opts, :codec) || Config.codec()
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
