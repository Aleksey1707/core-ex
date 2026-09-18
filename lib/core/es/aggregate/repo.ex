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
  - `get_decision(id, version, context, fun, opts)` → `{:ok, decision} | {:error, reason}` —
    решение `fun.(state)` над состоянием из потока; явная версия на пустом потоке сверяется после
    решения (ADR-0016);
  - `get_many(pairs, context, opts)` → `{:ok, [state]} | {:error, Error.t()}` — состояния в
    порядке пар `{id, version}`;
  - `append(events, context, opts)` → `:ok | {:error, Error.t()}` — запись событий
    `Agg.execute/2`;
  - `refresh(state, version, context, opts)` → `{:ok, state} | {:error, Error.t()}` — хвост
    потока после `state.version`;
  - `page_stream(id, limit, offset, context)` →
    `{:ok, Pagination.Result.t(Es.Event.t())} | {:error, Error.t()}` — страница потока агрегата
    для читающего usecase.

  Реализация — `use Core.Es.Aggregate.Repo.Pg` (исходы — там), резолв — `Core.Config.repo!/1`
  по конвенции `<Behaviour>.Pg`.

  Интроспекция — `__es_aggregate_repo__/0`: по ней `use Core.Es.Aggregate.Process` находит
  агрегат и Prim идентификатора.

  ## Полнота `evolve`

  Сборка репозитория проверяет `evolve/2` агрегата по его кодеку событий: на каждое событие макрос
  генерирует функцию-проверку (`Core.Es.Check`) — литеральный вызов
  `Agg.evolve(%Agg{} = state, %Event.Mod{payload: %Payload{}} = event)`, у события без нагрузки
  `payload: nil`. Предупреждение компилятора указывает на строку `use`, а имя функции в нём
  называет нарушенное утверждение — `"evolve/2 принимает <Event>"`. Ловятся:

  - событие кодека без clause `evolve/2`;
  - опечатка в ключе `%{state | …}`;
  - опечатка в поле нагрузки, которую clause не сузила паттерном `%Payload{}`.

  Агрегат без репозитория полноту `evolve` не проверяет. Кодек агрегата грузится при сборке
  репозитория; не кодек событий — `CompileError`. Макрос занимает в вызывающем модуле имена
  функций-проверок, по одному на событие кодека.

  ## Opts

  - `aggregate:` — модуль агрегата (`use Core.Es.Aggregate`); тип состояния — его `t()`
  - `id:` — Prim идентификатора агрегата
  """

  alias Core.Es
  alias Core.Helper

  @label "Es.Aggregate.Repo"
  @required_keys ~w(aggregate id)a
  @optional_keys []
  @callbacks [get: 4, get_decision: 5, get_many: 3, append: 3, refresh: 4, page_stream: 4]

  # ===== объявление =====

  @doc "Объявить behaviour write-репозитория event-sourced агрегата."
  defmacro __using__(opts) do
    lit = Macro.expand_literals(opts, __CALLER__)
    Helper.Opts.validate!(lit, @required_keys, @optional_keys, @label)
    aggregate = Helper.Opts.module!(lit, :aggregate, @label, exports: [__es_event_codec__: 0])
    id = Helper.Opts.module!(lit, :id, @label)

    quote do
      unquote_splicing(evolve_checks(aggregate, __CALLER__.line))

      @doc false
      @spec __es_aggregate_repo__() :: %{aggregate: module(), id: module()}

      def __es_aggregate_repo__, do: %{aggregate: unquote(aggregate), id: unquote(id)}

      @callback get(
                  id :: unquote(id).t(),
                  version :: Core.Version.expected(),
                  context :: Core.Context.t(),
                  opts :: keyword()
                ) :: {:ok, unquote(aggregate).t()} | {:error, Core.Error.t()}

      @callback get_decision(
                  id :: unquote(id).t(),
                  version :: Core.Version.expected(),
                  context :: Core.Context.t(),
                  fun :: (unquote(aggregate).t() -> {:ok, decision} | {:error, reason}),
                  opts :: keyword()
                ) :: {:ok, decision} | {:error, reason | Core.Error.t()}
                when decision: var, reason: var

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

      @callback page_stream(
                  id :: unquote(id).t(),
                  limit :: Core.Pagination.Limit.t(),
                  offset :: Core.Pagination.Offset.t(),
                  context :: Core.Context.t()
                ) :: {:ok, Core.Pagination.Result.t(Core.Es.Event.t())} | {:error, Core.Error.t()}
    end
  end

  # ---

  defp evolve_checks(aggregate, line) do
    event_codec = Es.Store.Opts.event_codec!(aggregate.__es_event_codec__(), @label)

    for event <- Enum.sort(event_codec.__es_mods__()) do
      args = [quote(do: %unquote(aggregate){} = state), quote(do: unquote(Es.Check.event_pattern(event)) = event)]
      Es.Check.define("evolve/2 принимает", event, args, quote(do: unquote(aggregate).evolve(state, event)), line)
    end
  end

  # ===== колбэки =====

  @doc false
  @spec callbacks() :: keyword(arity())

  def callbacks, do: @callbacks
end
