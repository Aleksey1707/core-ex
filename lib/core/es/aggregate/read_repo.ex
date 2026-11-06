defmodule Core.Es.Aggregate.ReadRepo do
  @moduledoc """
  Билдер behaviour read-репозитория event-sourced агрегата: состояние на версии представлением
  (`use`).

      defmodule MyApp.Domain.<BC>.Account.AtVersion.ReadRepo do
        use Core.Es.Aggregate.ReadRepo,
          repo: MyApp.Domain.<BC>.Account.Repo,
          view: MyApp.Domain.<BC>.Account.AtVersion.View
      end

  Пара модулей read-пути — этот behaviour и реализация `use Core.Es.Aggregate.ReadRepo.Pg` —
  заменяет копию агрегата адресом версии `{id, N}`: состояние на версии сворачивается в
  библиотеке и наружу уходит только `%View{}`. Решение от него принять нельзя, а
  `%Agg{}` потребитель видит только аргументом `to_view:` реализации.

  Генерирует `@callback get_at/3,4` → `Core.Result.t(view.t())`. Реализация резолвится
  `Core.Config.repo!/1` по конвенции `<Behaviour>.Pg`; агрегат и Prim идентификатора берутся у
  write-репозитория (`__es_aggregate_repo__/0`).

  Интроспекция — `__es_read_repo__/0`: по ней `use Core.Es.Aggregate.ReadRepo.Pg` находит
  write-репозиторий, View и голову `get_at`.

  Нормы чтения — `docs/rules/13-repos.md`, «Состояние на версии».

  ## Opts

  Все опции — литералы (`docs/rules/20-agreements.md`, «Опции `use`»): атрибут или вызов
  функции в опции — `CompileError` «ожидается литерал».

  - `repo:` — behaviour write-репозитория event-sourced агрегата (`use Core.Es.Aggregate.Repo`)
  - `view:` — представление read-модели (`use Core.View`)
  """

  alias Core.Es
  alias Core.Helper

  @label "Es.Aggregate.ReadRepo"
  @required_keys ~w(repo view)a
  @optional_keys []
  @expression_keys []

  @doc "Объявить behaviour read-репозитория состояния на версии."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)
    repo = repo!(opts)
    view = Helper.Opts.module!(opts, :view, @label, exports: [__view__: 0])
    %{aggregate: aggregate, id: id} = repo.__es_aggregate_repo__()

    quote do
      @doc false
      @spec __es_read_repo__() :: %{repo: module(), view: module(), aggregate: module(), id: module()}

      def __es_read_repo__,
        do: %{
          repo: unquote(repo),
          view: unquote(view),
          aggregate: unquote(aggregate),
          id: unquote(id)
        }

      @callback get_at(
                  id :: unquote(id).t(),
                  version :: Core.Version.t(),
                  context :: Core.Context.t()
                ) :: Core.Result.t(unquote(view).t())

      @callback get_at(
                  id :: unquote(id).t(),
                  version :: Core.Version.t(),
                  context :: Core.Context.t(),
                  opts :: keyword()
                ) :: Core.Result.t(unquote(view).t())
    end
  end

  # ---

  defp repo!(opts) do
    repo = Helper.Opts.module!(opts, :repo, @label, exports: [__es_aggregate_repo__: 0])

    case Es.Aggregate.Repo.callbacks() -- repo.behaviour_info(:callbacks) do
      [] ->
        repo

      missing ->
        Helper.Opts.reject!(
          "#{@label}: repo",
          "#{inspect(repo)} должен объявлять #{inspect(missing)} (use Core.Es.Aggregate.Repo)"
        )
    end
  end
end
