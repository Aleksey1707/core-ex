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
  голова потока читается через `get` write-репозитория.

  Состояние на версии сворачивает `@doc false` путь write-репозитория: снапшот не выше `N`,
  события до `N` включительно, снапшоты не пишутся. Адрес за головой потока или на пустом
  потоке — `:version_mismatch` каталога `errors:` write-репозитория с `source: :address`.
  `%Agg{}` уходит только аргументом `to_view:`; наружу — `%View{}`.

  Реализация write-репозитория резолвится `Core.Config.repo!/1` по конвенции
  `<Behaviour>.Pg` на компиляции. Telemetry — `[:es, :aggregate, :load]` и
  `[:es, :aggregate, :fold]` с `op: :get_at`; span'а нет.

  Функции `defoverridable` с сохранением закрытой головы и сужения. Нормы —
  `docs/rules/13-repos.md`, «Состояние на версии».

  ## Opts

  Все опции — литералы (`docs/rules/20-agreements.md`, «Опции `use`»); `to_view:` —
  опция-выражение.

  - `behaviour:` — `use Core.Es.Aggregate.ReadRepo`
  - `to_view:` — захват функции арности 1 `%Agg{} → %View{}`
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
    to_view = Keyword.fetch!(opts, :to_view)

    quote generated: true do
      @behaviour unquote(behaviour)

      require Core.Config

      @es_read_repo %{
        repo: Core.Config.repo!(unquote(repo)),
        view: unquote(view),
        to_view: Core.Es.Aggregate.ReadRepo.Pg.to_view!(unquote(to_view), unquote(behaviour))
      }

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

      defoverridable get_at: 3, get_at: 4
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
