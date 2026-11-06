defmodule Core.Es.Aggregate.ReadRepo.Pg do
  @moduledoc """
  Реализация read-репозитория состояния event-sourced агрегата на версии через его
  write-репозиторий (`use`).

      defmodule MyApp.Domain.<BC>.Account.AtVersion.ReadRepo.Pg do
        use Core.Es.Aggregate.ReadRepo.Pg,
          behaviour: MyApp.Domain.<BC>.Account.AtVersion.ReadRepo,
          to_view: &MyApp.Domain.<BC>.Account.AtVersion.View.from_state/1
      end

  Генерирует `get_at/3,4` с головой `%Agg.ID{}` + `%Version{}` + `%Context{}`:
  `{:ok, %View{}} | {:error, %Error{}}`. `:current` вместо `%Version{}` — `FunctionClauseError`:
  голова потока читается через `get` write-репозитория. `get_many_at/2,3` принимает список пар
  `{%Agg.ID{}, %Version{}}` и отдаёт представления в порядке пар: один поток читается один раз
  до наибольшей версии его пар, снятие состояния на версии выполняется для каждой версии; повтор
  пары и разные версии одного id разрешены, `[]` — `{:ok, []}` без запросов. Элемент не пара —
  `FunctionClauseError`.

  Состояние на версии сворачивает `@doc false` путь write-репозитория: снапшот не выше `N`,
  события до `N` включительно, снапшоты не пишутся. У пакета снапшот берётся только не выше
  наименьшей версии пар id, иначе поток читается с начала. Адрес за головой потока или на пустом
  потоке — `:version_mismatch` каталога `errors:` write-репозитория с `source: :address`; у пакета
  это одна ошибка со списком detail в порядке пар.
  `%Agg{}` уходит только аргументом `to_view:`; наружу — `%View{}`.

  Реализация write-репозитория резолвится `Core.Config.repo!/1` по конвенции
  `<Behaviour>.Pg` на компиляции. Telemetry — `[:es, :aggregate, :load]` и
  `[:es, :aggregate, :fold]` с `op: :get_at` / `:get_many_at`; span'а нет.

  Функции `defoverridable` с сохранением закрытой головы и сужения. Нормы —
  `docs/rules/13-repos.md`, «Состояние на версии».

  ## Opts

  Все опции — литералы (`docs/rules/20-agreements.md`, «Опции `use`»); `to_view:` —
  опция-выражение.

  - `behaviour:` — `use Core.Es.Aggregate.ReadRepo`
  - `to_view:` — захват функции арности 1 `%Agg{} → %View{}`

  Макрос занимает в вызывающем модуле имя `@es_read_repo` и приватную `es_read_repo_to_view!/2`.
  """

  alias Core.Es.Aggregate.ReadRepo
  alias Core.Helper

  @label "Es.Aggregate.ReadRepo.Pg"
  @required_keys ~w(behaviour to_view)a
  @optional_keys []
  @expression_keys ~w(to_view)a

  @doc "Реализовать чтение состояния event-sourced агрегата на версии."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)
    behaviour = behaviour!(opts)
    %{repo: repo, aggregate: aggregate, id: id, view: view} = behaviour.__es_read_repo__()
    to_view = to_view_expr!(Keyword.fetch!(opts, :to_view), behaviour)

    quote generated: true do
      @behaviour unquote(behaviour)

      require Core.Config

      @es_read_repo %{
        repo: Core.Config.repo!(unquote(repo)),
        view: unquote(view),
        to_view: Core.Es.Aggregate.ReadRepo.Pg.to_view!(unquote(to_view), unquote(behaviour))
      }

      Core.Es.Aggregate.ReadRepo.Pg.ensure_write_repo!(@es_read_repo.repo, unquote(repo))

      @doc "Представление агрегата на версии из свёрнутого до неё состояния."
      @impl true
      def get_at(
            %unquote(id){} = id,
            %Core.Version{} = version,
            %Core.Context{} = context,
            opts \\ []
          )
          when is_list(opts) do
        case @es_read_repo.repo.__es_get_at__(id, version, context, opts) do
          {:ok, %unquote(aggregate){} = state} ->
            case @es_read_repo.to_view.(state) do
              %unquote(view){} = view -> {:ok, view}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end

      @doc "Представления агрегатов на версиях из свёрнутых до них состояний, в порядке пар."
      @impl true
      def get_many_at(pairs, %Core.Context{} = context, opts \\ [])
          when is_list(pairs) and is_list(opts) do
        case @es_read_repo.repo.__es_get_many_at__(pairs, context, opts) do
          {:ok, states} when is_list(states) ->
            views = for state <- states, do: es_read_repo_to_view!(state, @es_read_repo.to_view)
            {:ok, views}

          {:error, reason} ->
            {:error, reason}
        end
      end

      defp es_read_repo_to_view!(%unquote(aggregate){} = state, to_view) do
        case to_view.(state) do
          %unquote(view){} = view -> view
        end
      end

      defoverridable get_at: 3, get_at: 4, get_many_at: 2, get_many_at: 3
    end
  end

  @doc false
  @spec ensure_write_repo!(module(), module()) :: module()

  def ensure_write_repo!(repo, behaviour) do
    missing =
      for {fun, arity} <- [__es_get_at__: 4, __es_get_many_at__: 3],
          not Helper.Module.exports?(repo, fun, arity),
          do: {fun, arity}

    case missing do
      [] ->
        repo

      missing ->
        Helper.Opts.reject!(
          "#{@label}: repo",
          "модуль #{inspect(repo)} должен экспортировать #{inspect(missing)} " <>
            "(write-репозиторий `use Core.Es.Aggregate.Repo.Pg`, behaviour: #{inspect(behaviour)})"
        )
    end
  end

  @doc false
  @spec to_view!(term(), module()) :: (struct() -> struct())

  def to_view!(fun, _behaviour) when is_function(fun, 1), do: fun

  def to_view!(other, behaviour) do
    Helper.Opts.reject!(
      "#{@label}: to_view",
      "ожидается захват функции арности 1 (`&Mod.fun/1`), получено #{inspect(other)} " <>
        "(behaviour: #{inspect(behaviour)})"
    )
  end

  # ---

  # Захват `&Mod.fun/1` или локальный `&fun/1` — единственная форма, которая разворачивается в
  # функцию на этапе раскрытия. Атрибут с захватом проверяется в рантайме тела модуля.
  defp to_view_expr!(to_view, behaviour) do
    if capture1?(to_view) or attribute?(to_view) do
      to_view
    else
      Helper.Opts.reject!(
        "#{@label}: to_view",
        "ожидается захват функции арности 1 (`&Mod.fun/1`), получено #{Macro.to_string(to_view)} " <>
          "(behaviour: #{inspect(behaviour)})"
      )
    end
  end

  defp capture1?({:&, _, [{:/, _, [_, 1]}]}), do: true
  defp capture1?(_), do: false

  defp attribute?({:@, _, [{name, _, _}]}) when is_atom(name), do: true
  defp attribute?(_), do: false

  defp behaviour!(opts) do
    behaviour = Helper.Opts.module!(opts, :behaviour, @label)

    unless Helper.Module.exports?(behaviour, :__es_read_repo__, 0) do
      Helper.Opts.reject!(
        "#{@label}: behaviour",
        "модуль #{inspect(behaviour)} должен экспортировать __es_read_repo__/0 " <>
          "(use Core.Es.Aggregate.ReadRepo)"
      )
    end

    case ReadRepo.callbacks() -- behaviour.behaviour_info(:callbacks) do
      [] ->
        behaviour

      missing ->
        Helper.Opts.reject!(
          "#{@label}: behaviour",
          "модуль #{inspect(behaviour)} должен объявлять #{inspect(missing)} (use Core.Es.Aggregate.ReadRepo)"
        )
    end
  end
end
