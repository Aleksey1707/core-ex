defmodule Core.Es.Event.Repo.Pg.Schema do
  @moduledoc """
  Билдер Ecto-схемы таблицы событий агрегата.

      use Core.Es.Event.Repo.Pg.Schema,
        table: "role_events",
        event: MyApp.Domain.<BC>.Common.Role.Event,
        by_schema: MyApp.Domain.Users.Common.User.Repo.Pg.Schema,
        payload_type: MyApp.DAO.Types.JSON

  Колонки таблицы фиксированы: `id`, `type`, `payload`, `aggregate_id`, `aggregate_version`,
  `at`, `by_id`. Генерирует схему, `to_model/1`, `to_model!/1`, `to_entity/1`, `to_entity!/1`.

  Событие переводится в строку и обратно через фасад (`codec.dump/1` и `codec.load/2` по
  модулю событий агрегата), а поля конверта раскладываются по колонкам парой
  `Core.Es.Event.Codec.to_fields/1` и `from_fields/1`: имена колонок остаются здесь, ключи
  конверта — в кодеке. Конкретный тип события кодек выбирает по тегу, поэтому схеме не
  нужны ни он сам, ни Prim агрегата.

  `changeset/2` не генерируется: события пишутся только через `insert_all` (см.
  `Core.Es.Event.Repo.Pg`), конфликт `(aggregate_id, aggregate_version)` обрабатывает `append/2`.

  ## Opts

  - `table:` — имя таблицы событий
  - `event:` — объединяющий модуль событий агрегата
  - `by_schema:` — Ecto-схема таблицы пользователей (для `belongs_to :by`)
  - `payload_type:` — Ecto-тип колонки `payload`
  - `codec:` — entity-фасад Codec; по умолчанию резолвится в рантайме
    через `Core.Config.codec()`

  Макрос занимает имя `@es_event` и приватную `es_codec/0`.
  """

  alias Core.Helper

  @label "Es.Event.Repo.Pg.Schema"
  @required_keys ~w(table event by_schema payload_type)a
  @optional_keys ~w(codec)a

  @doc "Объявить Ecto-схему таблицы событий агрегата."
  defmacro __using__(opts) do
    opts =
      opts
      |> Macro.expand_literals(__CALLER__)
      |> validate_opts!()

    quote do
      use Ecto.Schema

      @es_event unquote(opts.event)

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
        fields =
          event
          |> es_codec().dump()
          |> Core.Es.Event.Codec.to_fields()

        {:ok,
         %{
           id: fields.id,
           type: fields.type,
           payload: fields.payload,
           aggregate_id: fields.aggregate_id,
           aggregate_version: fields.aggregate_version,
           at: fields.at,
           by_id: fields.by
         }}
      end

      @doc "Событие → map или `Exc`."
      @spec to_model!(event()) :: map()

      def to_model!(event), do: Core.Result.unwrap!(to_model(event))

      @doc "Строка БД → доменное событие."
      @spec to_entity(t()) :: {:ok, event()} | {:error, Core.Error.t()}

      def to_entity(%__MODULE__{} = row) do
        %{
          id: row.id,
          type: row.type,
          payload: row.payload,
          aggregate_id: row.aggregate_id,
          aggregate_version: row.aggregate_version,
          at: row.at,
          by: row.by_id
        }
        |> Core.Es.Event.Codec.from_fields()
        |> then(&es_codec().load(@es_event, &1))
      end

      @doc "Строка БД → доменное событие или `Exc`."
      @spec to_entity!(t()) :: event()

      def to_entity!(%__MODULE__{} = row), do: Core.Result.unwrap!(to_entity(row))

      defp es_codec, do: unquote(opts.codec)
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

    %{
      table: Helper.Opts.binary!(opts, :table, @label),
      event: Helper.Opts.module!(opts, :event, @label),
      by_schema: Helper.Opts.module!(opts, :by_schema, @label),
      payload_type: Helper.Opts.module!(opts, :payload_type, @label),
      codec: Helper.Opts.module_or_config!(opts, :codec, :codec, @label)
    }
  end
end
