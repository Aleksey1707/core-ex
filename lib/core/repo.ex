defmodule Core.Repo do
  @moduledoc """
  Билдер behaviour репозитория: `use Core.Repo, only: :full | :permanent | :read | [atoms]`.

  Генерирует `@callback` для выбранного набора методов. Реализация — `Core.Repo.Pg`
  (generic PostgreSQL) либо ручной модуль.

  Пресеты `only:`:

  | Значение | Методы |
  |---|---|
  | `:full` | все, включая `delete` |
  | `:permanent` | все, кроме `delete` |
  | `:read` | только чтение |
  | список | явный набор |

  ## Тип элемента: `entity:` или `view:`

  Write-репозиторий работает с агрегатом на доменных Prim (`entity:`), read-репозиторий —
  с представлением из примитивных значений (`view:`, см. `13-repos.md`). Опции
  взаимоисключающие, и `view:` допустим только при read-наборе методов: инвариант
  «write — агрегат, read — View» проверяет компилятор, а не ревью.

  Без `entity:` / `view:` элемент типизируется как `struct()`, без `id:` — как `term()`.
  """

  alias Core.Helper
  alias Core.Version

  @type version :: Version.t() | :current
  @type opts :: keyword()

  @read_methods ~w(get get! list page find_many get_many exists? exists_all? count)a
  @write_methods ~w(insert update save)a
  @permanent_methods @read_methods ++ @write_methods
  @full_methods @permanent_methods ++ ~w(delete)a
  @known_methods @full_methods
  @label "Repo"
  @required_keys ~w()a
  @optional_keys ~w(only entity view id)a

  @doc "Объявить Repo behaviour (`only:` — :full / :permanent / :read / список)."
  defmacro __using__(opts) do
    opts
    |> Macro.expand_literals(__CALLER__)
    |> expand_only!(__CALLER__)
    |> validate_opts!()
    |> callbacks()
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @doc false
  @spec known_methods() :: [atom()]

  def known_methods, do: @known_methods

  @doc false
  @spec read_methods() :: [atom()]

  def read_methods, do: @read_methods

  @doc false
  @spec write_methods() :: [atom()]

  def write_methods, do: @write_methods

  @doc false
  @spec expand_only(:full | :permanent | :read | [atom()]) :: [atom()]

  def expand_only(:full), do: @full_methods

  def expand_only(:permanent), do: @permanent_methods

  def expand_only(:read), do: @read_methods

  def expand_only(list) when is_list(list), do: list

  def expand_only(other) do
    raise CompileError, description: "unknown repository kind: #{inspect(other)}"
  end

  # ---

  # `only:` разбирается по AST, а не через `bind_quoted`, поэтому `~w(get save)a` доезжает
  # сюда невычисленным вызовом макроса `sigil_w`. Список атомов — предписанная проектом
  # форма записи (`.claude/rules/20-agreements.md`), так что разворачивать её обязан билдер.
  defp expand_only!(opts, env) do
    case Keyword.fetch(opts, :only) do
      {:ok, value} -> Keyword.put(opts, :only, Macro.expand(value, env))
      :error -> opts
    end
  end

  defp validate_opts!(opts) do
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)

    only =
      opts
      |> Keyword.get(:only, :full)
      |> expand_only()
      |> Enum.uniq()

    Helper.Opts.allowed!(only, @known_methods, "method(s)", @label)

    %{only: only, item: item_type!(opts, only), id: id_type!(opts)}
  end

  defp item_type!(opts, only) do
    opts
    |> Keyword.take(~w(entity view)a)
    |> Keyword.keys()
    |> Enum.uniq()
    |> item_type(opts, only)
  end

  defp item_type([], _opts, _only), do: quote(do: struct())

  defp item_type([:entity], opts, _only), do: remote_type(opts, :entity)

  defp item_type([:view], opts, only) do
    reject_write_methods!(only)
    remote_type(opts, :view)
  end

  defp item_type(_entity_and_view, _opts, _only) do
    raise CompileError,
      description: "#{@label}: entity: и view: взаимоисключающие (write — агрегат, read — View)"
  end

  defp id_type!(opts) do
    if Keyword.has_key?(opts, :id),
      do: remote_type(opts, :id),
      else: quote(do: term())
  end

  # View — представление query-пути: у методов записи его быть не может (`13-repos.md`).
  defp reject_write_methods!(only) do
    case Enum.filter(only, &(&1 in @write_methods or &1 == :delete)) do
      [] ->
        :ok

      found ->
        raise CompileError,
          description:
            "#{@label}: view: допустим только для read-методов, найдены: #{inspect(found)}"
    end
  end

  defp remote_type(opts, key) do
    mod = Helper.Opts.module!(opts, key, @label)

    quote(do: unquote(mod).t())
  end

  defp callbacks(cfg), do: {:__block__, [], Enum.map(cfg.only, &callback(&1, cfg))}

  defp callback(:get, cfg) do
    quote do
      @callback get(
                  id :: unquote(cfg.id),
                  version :: Core.Repo.version(),
                  context :: Core.Context.t(),
                  opts :: Core.Repo.opts()
                ) ::
                  {:ok, unquote(cfg.item)} | {:error, Core.Error.t()}
    end
  end

  defp callback(:get!, cfg) do
    quote do
      @callback get!(
                  id :: unquote(cfg.id),
                  version :: Core.Repo.version(),
                  context :: Core.Context.t(),
                  opts :: Core.Repo.opts()
                ) :: unquote(cfg.item)
    end
  end

  defp callback(:list, cfg) do
    quote do
      @callback list(
                  context :: Core.Context.t(),
                  opts :: Core.Repo.opts()
                ) :: [unquote(cfg.item)]
    end
  end

  defp callback(:page, cfg) do
    quote do
      @callback page(
                  limit :: Core.Pagination.Limit.t(),
                  offset :: Core.Pagination.Offset.t(),
                  context :: Core.Context.t(),
                  opts :: Core.Repo.opts()
                ) :: Core.Pagination.Result.t(unquote(cfg.item))
    end
  end

  defp callback(:find_many, cfg) do
    quote do
      @callback find_many(
                  pairs :: [{unquote(cfg.id), Core.Repo.version()}],
                  context :: Core.Context.t(),
                  opts :: Core.Repo.opts()
                ) :: {:ok, [unquote(cfg.item)]} | {:error, Core.Error.t()}
    end
  end

  defp callback(:get_many, cfg) do
    quote do
      @callback get_many(
                  pairs :: [{unquote(cfg.id), Core.Repo.version()}],
                  context :: Core.Context.t(),
                  opts :: Core.Repo.opts()
                ) :: {:ok, [unquote(cfg.item)]} | {:error, Core.Error.t()}
    end
  end

  defp callback(:insert, cfg) do
    quote do
      @callback insert(
                  entity :: unquote(cfg.item),
                  context :: Core.Context.t(),
                  opts :: Core.Repo.opts()
                ) ::
                  {:ok, unquote(cfg.item)}
                  | {:error, Core.Error.t()}
                  | {:error, Ecto.Changeset.t()}
    end
  end

  defp callback(:update, cfg) do
    quote do
      @callback update(
                  entity :: unquote(cfg.item),
                  context :: Core.Context.t(),
                  opts :: Core.Repo.opts()
                ) ::
                  {:ok, unquote(cfg.item)}
                  | {:error, Core.Error.t()}
                  | {:error, Ecto.Changeset.t()}
    end
  end

  defp callback(:save, cfg) do
    quote do
      @callback save(
                  entity :: unquote(cfg.item),
                  context :: Core.Context.t(),
                  opts :: Core.Repo.opts()
                ) ::
                  {:ok, unquote(cfg.item)}
                  | {:error, Core.Error.t()}
                  | {:error, Ecto.Changeset.t()}
    end
  end

  defp callback(:delete, cfg) do
    quote do
      @callback delete(
                  id :: unquote(cfg.id),
                  version :: Core.Repo.version(),
                  context :: Core.Context.t(),
                  opts :: Core.Repo.opts()
                ) :: :ok | {:error, Core.Error.t()}
    end
  end

  defp callback(:exists?, cfg) do
    quote do
      @callback exists?(
                  id :: unquote(cfg.id),
                  version :: Core.Repo.version(),
                  context :: Core.Context.t(),
                  opts :: Core.Repo.opts()
                ) :: {:ok, boolean()} | {:error, Core.Error.t()}
    end
  end

  defp callback(:exists_all?, cfg) do
    quote do
      @callback exists_all?(
                  pairs :: [{unquote(cfg.id), Core.Repo.version()}],
                  context :: Core.Context.t(),
                  opts :: Core.Repo.opts()
                ) :: {:ok, boolean()} | {:error, Core.Error.t()}
    end
  end

  defp callback(:count, _cfg) do
    quote do
      @callback count(
                  context :: Core.Context.t(),
                  opts :: Core.Repo.opts()
                ) :: non_neg_integer()
    end
  end
end
