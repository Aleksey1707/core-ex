defmodule Core.Es.Event.Repo.Pg.Schema do
  @moduledoc """
  Билдер Ecto-схемы таблицы событий агрегата.

      use Core.Es.Event.Repo.Pg.Schema,
        table: "role_events",
        event: MyApp.Domain.<BC>.Common.Role.Event,
        aggregate_id: MyApp.Domain.<BC>.Common.Role.ID,
        by: MyApp.Domain.Users.Common.User.ID,
        by_schema: MyApp.Domain.Users.Common.User.Repo.Pg.Schema,
        payload_type: MyApp.DAO.Types.JSON

  Колонки таблицы фиксированы: `id`, `type`, `payload`, `aggregate_id`, `aggregate_version`,
  `at`, `by_id`. Генерирует схему, `to_model/1`, `to_model!/1`, `to_entity/1`, `to_entity!/1`.

  `changeset/2` не генерируется: события пишутся только через `insert_all` (см.
  `Core.Es.Event.Repo.Pg`), конфликт `(aggregate_id, aggregate_version)` обрабатывает `append/2`.

  ## Opts

  - `table:` — имя таблицы событий
  - `event:` — объединяющий модуль событий агрегата
  - `aggregate_id:` — Prim идентификатора агрегата
  - `by:` — Prim идентификатора автора события
  - `by_schema:` — Ecto-схема таблицы пользователей (для `belongs_to :by`)
  - `payload_type:` — Ecto-тип колонки `payload`
  - `event_codec:` — кодек событий; по умолчанию `<event>.Codec`
  - `codec:` — entity-фасад Codec; по умолчанию `Core.Config.codec()`

  Макрос занимает имена `@es_event`, `@es_event_codec`, `@es_aggregate_id`, `@es_by`, `@es_codec`.
  """

  alias Core.Config
  alias Core.Helper

  @label "Es.Event.Repo.Pg.Schema"
  @required_keys ~w(table event aggregate_id by by_schema payload_type)a
  @optional_keys ~w(event_codec codec)a

  @doc "Объявить Ecto-схему таблицы событий агрегата."
  defmacro __using__(opts) do
    opts =
      opts
      |> Macro.expand_literals(__CALLER__)
      |> validate_opts!()

    quote do
      use Ecto.Schema

      @es_event unquote(opts.event)
      @es_event_codec unquote(opts.event_codec)
      @es_aggregate_id unquote(opts.aggregate_id)
      @es_by unquote(opts.by)
      @es_codec unquote(opts.codec)

      @primary_key {:id, :binary_id, autogenerate: false}
      @foreign_key_type :binary_id

      schema unquote(opts.table) do
        field :type, :string
        field :payload, unquote(opts.payload_type)
        field :aggregate_id, :binary_id
        field :aggregate_version, :integer
        field :at, :utc_datetime

        belongs_to :by, unquote(opts.by_schema), foreign_key: :by_id, type: :binary_id
      end

      @type t :: %__MODULE__{}

      @typedoc "Событие агрегата."
      @type event :: unquote(opts.event).t()

      @doc "Событие → map для `insert_all`."
      @spec to_model(event()) :: {:ok, map()} | {:error, Core.Error.t()}

      def to_model(event) do
        {type, payload} = @es_codec.dump(event)

        {:ok,
         %{
           id: @es_codec.dump(event.id),
           type: type,
           payload: payload,
           aggregate_id: @es_codec.dump(event.aggregate_id),
           aggregate_version: Core.Version.value(event.aggregate_version),
           at: @es_codec.dump(event.at),
           by_id: @es_codec.dump(event.by)
         }}
      end

      @doc "Событие → map или `Exc`."
      @spec to_model!(event()) :: map()

      def to_model!(event), do: Core.Result.unwrap!(to_model(event))

      @doc "Строка БД → доменное событие."
      @spec to_entity(t()) :: {:ok, event()} | {:error, Core.Error.t()}

      def to_entity(%__MODULE__{} = row) do
        with {:ok, aggregate_id} <- @es_aggregate_id.new(row.aggregate_id),
             {:ok, version} <- Core.Version.new(row.aggregate_version),
             {:ok, by} <- @es_by.new(row.by_id),
             {:ok, at} <- Core.Es.Event.At.new(row.at),
             {:ok, id} <- Core.Es.Event.ID.new(row.id) do
          @es_event_codec.load_event(
            row.type,
            row.payload,
            aggregate_id,
            version,
            by,
            at,
            id,
            @es_codec
          )
        end
      end

      @doc "Строка БД → доменное событие или `Exc`."
      @spec to_entity!(t()) :: event()

      def to_entity!(%__MODULE__{} = row), do: Core.Result.unwrap!(to_entity(row))
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

    event = Helper.Opts.module!(opts, :event, @label)

    %{
      table: Helper.Opts.binary!(opts, :table, @label),
      event: event,
      # Компайл-тайм резолв дефолтного кодека: модуль ещё не загружен, safe_concat непригоден.
      # credo:disable-for-lines:5 Credo.Check.Warning.UnsafeToAtom
      event_codec:
        Helper.Opts.module!(opts, :event_codec, @label,
          default: Module.concat(event, Codec),
          exports: [load_event: 8]
        ),
      aggregate_id: Helper.Opts.module!(opts, :aggregate_id, @label, exports: [new: 1]),
      by: Helper.Opts.module!(opts, :by, @label, exports: [new: 1]),
      by_schema: Helper.Opts.module!(opts, :by_schema, @label),
      payload_type: Helper.Opts.module!(opts, :payload_type, @label),
      codec: Keyword.get(opts, :codec) || Config.codec()
    }
  end
end
