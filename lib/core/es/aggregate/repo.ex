defmodule Core.Es.Aggregate.Repo do
  @moduledoc """
  Билдер behaviour write-репозитория event-sourced агрегата (`use`).

      defmodule MyApp.Domain.<BC>.Common.Account.Repo do
        use Core.Es.Aggregate.Repo,
          aggregate: MyApp.Domain.<BC>.Common.Account,
          id: MyApp.Domain.<BC>.Common.Account.ID
      end

  Генерирует `@callback`:

  - `get(id, version, context, opts)` → `{:ok, state} | {:error, Error.t()}` — состояние из
    потока агрегата;
  - `get_many(pairs, context, opts)` → `{:ok, [state]} | {:error, Error.t()}` — состояния в
    порядке пар `{id, version}`;
  - `append(events, context, opts)` → `:ok | {:error, Error.t()}` — запись событий
    `Agg.execute/2`;
  - `refresh(state, version, context, opts)` → `{:ok, state} | {:error, Error.t()}` — хвост
    потока после `state.version`.

  Реализация — `use Core.Es.Aggregate.Repo.Pg` (исходы — там), резолв — `Core.Config.repo!/1`
  по конвенции `<Behaviour>.Pg`.

  Интроспекция — `__es_aggregate_repo__/0`: по ней `use Core.Es.Aggregate.Process` находит
  агрегат и Prim идентификатора.

  ## Opts

  - `aggregate:` — модуль агрегата (`use Core.Es.Aggregate`); тип состояния — его `t()`
  - `id:` — Prim идентификатора агрегата
  """

  alias Core.Helper

  @label "Es.Aggregate.Repo"
  @required_keys ~w(aggregate id)a
  @optional_keys []
  @callbacks [get: 4, get_many: 3, append: 3, refresh: 4]

  @doc "Объявить behaviour write-репозитория event-sourced агрегата."
  defmacro __using__(opts) do
    lit = Macro.expand_literals(opts, __CALLER__)
    Helper.Opts.validate!(lit, @required_keys, @optional_keys, @label)
    aggregate = Helper.Opts.module!(lit, :aggregate, @label, exports: [__es_event_codec__: 0])
    id = Helper.Opts.module!(lit, :id, @label)

    quote do
      @doc false
      @spec __es_aggregate_repo__() :: %{aggregate: module(), id: module()}

      def __es_aggregate_repo__, do: %{aggregate: unquote(aggregate), id: unquote(id)}

      @callback get(
                  id :: unquote(id).t(),
                  version :: Core.Version.expected(),
                  context :: Core.Context.t(),
                  opts :: keyword()
                ) :: {:ok, unquote(aggregate).t()} | {:error, Core.Error.t()}

      @callback get_many(
                  pairs :: [{unquote(id).t(), Core.Version.expected()}],
                  context :: Core.Context.t(),
                  opts :: keyword()
                ) :: {:ok, [unquote(aggregate).t()]} | {:error, Core.Error.t()}

      @callback append(
                  events :: [Core.Es.Event.t()],
                  context :: Core.Context.t(),
                  opts :: keyword()
                ) :: :ok | {:error, Core.Error.t()}

      @callback refresh(
                  state :: unquote(aggregate).t(),
                  version :: Core.Version.expected(),
                  context :: Core.Context.t(),
                  opts :: keyword()
                ) :: {:ok, unquote(aggregate).t()} | {:error, Core.Error.t()}
    end
  end

  @doc false
  @spec callbacks() :: keyword(arity())

  def callbacks, do: @callbacks
end
