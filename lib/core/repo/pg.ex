defmodule Core.Repo.Pg do
  @moduledoc """
  Generic PostgreSQL-реализация Repo behaviour: `use Core.Repo.Pg, ...`.

  Макрос генерирует методы, объявленные в `behaviour:`, каждый — `defoverridable`, и кладёт в
  вызывающий модуль конфиг `@pg`. Реализации (`get/5`, `insert/4`, `save/4`, `version_error/4`,
  ...) публичны и принимают `@pg` первым аргументом — так их зовут модули, переопределившие
  метод.

  Макрос занимает в вызывающем модуле имена `@pg`, `@id_type`, `@entity_type` и добавляет
  `alias Context/Pagination/Repo/Version` + `import Version, only: [is_version: 1]`.

  ## Намеренное поведение

  - `insert/4` не применяет `default_filters` (в `INSERT` нет `WHERE`) и не пишет результат в
    `Repo.Sc` — в отличие от `get`/`list`/`page`. Для агрегата с дочерними таблицами строка,
    вернувшаяся из `insert`, содержит непрогруженные `has_many`, и её захват сделал бы эталон
    `Sc` неверным. Эталон после записи кладёт call site — `Repo.Pg.Es` зовёт `put_baseline/3`
    с входным domain-агрегатом (он полный, с детьми).
  - `find_many/4` отдаёт только найденные записи: и `not_found`, и `version_mismatch`
    отбрасываются молча. Строгий вариант — `get_many/4`.
  - `save/4` вызывает `insert/4` и `update/4` **этого** модуля, а не переопределённые в
    вызывающем. Модуль, переопределивший `insert`/`update` (запись детей, flush событий),
    обязан переопределить и `save`.
  - Ни один метод не открывает транзакцию: `save/4` — это 2-3 запроса, `delete/5` — 2.
    Атомарность обеспечивает call site (`Helper.Transact.run/3`).
  - `constraint_errors:` объявляется типом ограничения (`unique:` / `foreign_key:` / `check:` /
    `exclusion:`), а сверяется с `error_type` ошибки changeset: у `foreign_key_constraint/3` это
    `:foreign`, а не `:foreign_key`. Перевод делает макрос (`@error_types`) — иначе маппинг FK
    не совпал бы никогда. Соответствие деклараций `changeset/2` проверяет
    `test/<app>/repo/constraint_errors_test.exs`.

  ## Декодер строки: `to_entity:` или `to_view:`

  Write-репозиторий декодирует строку в агрегат на доменных Prim (`to_entity:`),
  read-репозиторий — в представление из примитивных значений (`to_view:`, см. `13-repos.md`).
  Опции взаимоисключающие; какая из них задана, видно по behaviour:

  | Behaviour | `to_entity:` | `to_view:` | `to_model:` |
  |---|---|---|---|
  | с `insert` / `update` / `save` | обязателен | запрещён | обязателен |
  | только чтение | допустим | допустим | не нужен |

  Guard по типу результата (аналог `@entity_type` для `insert`/`update`/`save`) у read-методов
  не заводится: представление никогда не приходит аргументом — на вход идут id, пагинация и
  `%Context{}`.
  """

  import Ecto.Query, only: [from: 2, exclude: 2]

  alias Core.Context
  alias Core.Error
  alias Core.Helper
  alias Core.Pagination
  alias Core.Repo
  alias Core.Result
  alias Core.Version

  @required_keys ~w(schema behaviour errors)a
  @optional_keys ~w(repo query default_filters to_entity to_model to_view to_id version_field
                    shadow_copy? id entity constraint_errors)a
  @known_error_codes ~w(not_found version_mismatch incomplete_result no_ids)a
  @constraint_types ~w(unique foreign_key check exclusion)a
  # Ecto кладёт в ошибку changeset не тип ограничения, а его error_type
  # (`Ecto.Changeset.add_constraint/7`): у `foreign_key_constraint/3` это `:foreign`,
  # у остальных совпадает с типом. Маппинг нормализуется к error_type на этапе компиляции.
  @error_types %{unique: :unique, foreign_key: :foreign, check: :check, exclusion: :exclusion}
  @insert_many_chunk_size 500

  @doc "Реализовать Repo behaviour через PostgreSQL (generic CRUD)."
  defmacro __using__(opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(
        opts,
        Core.Repo.Pg.required_keys(),
        Core.Repo.Pg.optional_keys(),
        "Repo.Pg"
      )

      shadow_copy? = Keyword.get(opts, :shadow_copy?, false)

      Helper.Opts.allowed!(shadow_copy?, [true, false], "shadow_copy?", "Repo.Pg")

      behaviour = Keyword.fetch!(opts, :behaviour)
      Code.ensure_compiled!(behaviour)
      @behaviour behaviour

      only =
        behaviour.behaviour_info(:callbacks)
        |> Enum.map(fn {name, _arity} -> name end)
        |> Enum.uniq()

      schema = Keyword.fetch!(opts, :schema)
      errors = Keyword.fetch!(opts, :errors)
      Core.Repo.Pg.validate_errors_module!(errors)

      constraint_errors =
        Core.Repo.Pg.normalize_constraint_errors!(Keyword.get(opts, :constraint_errors, []))

      Core.Repo.Pg.validate_constraint_error_codes!(errors, constraint_errors)
      Core.Repo.Pg.validate_mappers!(opts, only)

      @id_type Keyword.get(opts, :id)
      @entity_type Keyword.get(opts, :entity)

      @pg %{
        dao: Keyword.get(opts, :repo) || Core.Config.dao(),
        module: behaviour,
        schema: schema,
        query: Keyword.get(opts, :query, schema),
        default_filters: Keyword.get(opts, :default_filters, &Core.Repo.Pg.always_true/1),
        to_entity: Keyword.get(opts, :to_view) || Keyword.fetch!(opts, :to_entity),
        to_model: Keyword.get(opts, :to_model),
        to_id: Keyword.get(opts, :to_id, &Function.identity/1),
        version_field: Keyword.get(opts, :version_field, :version),
        shadow_copy?: shadow_copy?,
        errors: errors,
        constraint_errors: constraint_errors
      }

      alias Core.Context
      alias Core.Pagination
      alias Core.Repo
      alias Core.Version

      import Core.Version, only: [is_version: 1]

      @doc false
      @spec __constraint_errors__() :: {module(), %{{atom(), atom()} => atom()}}

      def __constraint_errors__, do: {@pg.schema, @pg.constraint_errors}

      if :get in only do
        @doc "Получить сущность по id и version."
        @impl true
        def get(id, version, %Context{} = context, opts \\ [])
            when (@id_type == nil or is_struct(id, @id_type)) and is_version(version) and
                   is_list(opts),
            do: Repo.Pg.get(@pg, id, version, context, opts)

        defoverridable get: 3, get: 4
      end

      if :get! in only do
        @doc "Получить сущность; при ошибке — raise."
        @impl true
        def get!(id, version, %Context{} = context, opts \\ [])
            when (@id_type == nil or is_struct(id, @id_type)) and is_version(version) and
                   is_list(opts),
            do: Repo.Pg.get!(@pg, id, version, context, opts)

        defoverridable get!: 3, get!: 4
      end

      if :list in only do
        @doc "Список сущностей в scope."
        @impl true
        def list(%Context{} = context, opts \\ []) when is_list(opts),
          do: Repo.Pg.list(@pg, context, opts)

        defoverridable list: 1, list: 2
      end

      if :page in only do
        @doc "Страница сущностей (limit/offset)."
        @impl true
        def page(
              %Pagination.Limit{} = limit,
              %Pagination.Offset{} = offset,
              %Context{} = context,
              opts \\ []
            )
            when is_list(opts),
            do: Repo.Pg.page(@pg, limit, offset, context, opts)

        defoverridable page: 3, page: 4
      end

      if :find_many in only do
        @doc "Найти сущности по парам id/version (без incomplete)."
        @impl true
        def find_many(pairs, %Context{} = context, opts \\ []) when is_list(opts),
          do: Repo.Pg.find_many(@pg, pairs, context, opts)

        defoverridable find_many: 2, find_many: 3
      end

      if :get_many in only do
        @doc "Получить все сущности по парам id/version."
        @impl true
        def get_many(pairs, %Context{} = context, opts \\ []) when is_list(opts),
          do: Repo.Pg.get_many(@pg, pairs, context, opts)

        defoverridable get_many: 2, get_many: 3
      end

      if :insert in only do
        @doc "Вставить сущность."
        @impl true
        def insert(entity, %Context{} = context, opts \\ [])
            when (@entity_type == nil or is_struct(entity, @entity_type)) and is_list(opts),
            do: Repo.Pg.insert(@pg, entity, context, opts)

        defoverridable insert: 2, insert: 3
      end

      if :update in only do
        @doc "Обновить сущность."
        @impl true
        def update(entity, %Context{} = context, opts \\ [])
            when (@entity_type == nil or is_struct(entity, @entity_type)) and is_list(opts),
            do: Repo.Pg.update(@pg, entity, context, opts)

        defoverridable update: 2, update: 3
      end

      if :save in only do
        @doc "Сохранить сущность (insert или update)."
        @impl true
        def save(entity, %Context{} = context, opts \\ [])
            when (@entity_type == nil or is_struct(entity, @entity_type)) and is_list(opts),
            do: Repo.Pg.save(@pg, entity, context, opts)

        defoverridable save: 2, save: 3
      end

      if :delete in only do
        @doc "Удалить сущность по id и version."
        @impl true
        def delete(id, version, %Context{} = context, opts \\ [])
            when (@id_type == nil or is_struct(id, @id_type)) and is_version(version) and
                   is_list(opts),
            do: Repo.Pg.delete(@pg, id, version, context, opts)

        defoverridable delete: 3, delete: 4
      end

      if :exists? in only do
        @doc "Проверить существование по id и version."
        @impl true
        def exists?(id, version, %Context{} = context, opts \\ [])
            when (@id_type == nil or is_struct(id, @id_type)) and is_version(version) and
                   is_list(opts),
            do: Repo.Pg.exists?(@pg, id, version, context, opts)

        defoverridable exists?: 3, exists?: 4
      end

      if :exists_all? in only do
        @doc "Проверить существование всех пар id/version."
        @impl true
        def exists_all?(pairs, %Context{} = context, opts \\ []) when is_list(opts),
          do: Repo.Pg.exists_all?(@pg, pairs, context, opts)

        defoverridable exists_all?: 2, exists_all?: 3
      end

      if :count in only do
        @doc "Число сущностей в scope."
        @impl true
        def count(%Context{} = context, opts \\ []) when is_list(opts),
          do: Repo.Pg.count(@pg, context, opts)

        defoverridable count: 1, count: 2
      end
    end
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @doc "Фильтр по умолчанию: без ограничений (дефолт опции `default_filters:`)."
  @spec always_true(Context.t()) :: true

  def always_true(_context), do: true

  @doc """
  Проверить пару декодер/энкодер строки против набора методов behaviour.

  `to_view:` — декодер read-пути: у behaviour с записью его быть не может, а `to_model:`
  наоборот обязателен (без него нечем собрать строку). Read-only behaviour `to_model:`
  принимает и игнорирует.
  """
  @spec validate_mappers!(keyword(), [atom()]) :: :ok

  def validate_mappers!(opts, only) do
    write? = Enum.any?(only, &(&1 in Repo.write_methods()))

    validate_decoder!(opts)
    validate_encoder!(opts, write?)
  end

  # ---

  defp validate_decoder!(opts) do
    opts
    |> Keyword.take(~w(to_entity to_view)a)
    |> Keyword.keys()
    |> Enum.uniq()
    |> ensure_single_decoder!()
  end

  defp ensure_single_decoder!([_one]), do: :ok

  defp ensure_single_decoder!([]) do
    raise CompileError,
      description:
        "to_entity/to_view: нужен декодер строки — to_entity: (write) или to_view: (read)"
  end

  defp ensure_single_decoder!(_entity_and_view) do
    raise CompileError,
      description: "to_entity/to_view: взаимоисключающие (write — агрегат, read — View)"
  end

  defp validate_encoder!(opts, true) do
    if Keyword.has_key?(opts, :to_view) do
      raise CompileError,
        description: "to_view: недопустим для behaviour с insert/update/save"
    end

    unless Keyword.has_key?(opts, :to_model) do
      raise CompileError,
        description: "to_model: обязателен для behaviour с insert/update/save"
    end

    :ok
  end

  defp validate_encoder!(_opts, false), do: :ok

  @doc false
  @spec validate_errors_module!(module()) :: :ok

  def validate_errors_module!(errors) when is_list(errors) do
    raise CompileError, description: "errors: ожидается модуль Errors, получен keyword"
  end

  def validate_errors_module!(errors) when is_atom(errors) do
    Code.ensure_compiled!(errors)

    unless function_exported?(errors, :domain, 3) do
      raise CompileError,
        description: "errors: модуль #{inspect(errors)} должен экспортировать domain/3"
    end

    Enum.each(@known_error_codes, fn code ->
      try do
        errors.domain(__MODULE__, code, nil)
      rescue
        FunctionClauseError ->
          reraise CompileError,
                  [
                    description:
                      "errors: отсутствует clause для #{inspect(code)} в #{inspect(errors)}"
                  ],
                  __STACKTRACE__
      end
    end)

    :ok
  end

  def validate_errors_module!(other) do
    raise CompileError,
      description: "errors: ожидается модуль Errors, получено #{inspect(other)}"
  end

  @doc false
  # Ключ результата — `{error_type, field}`, а не `{тип ограничения, field}`: сверка идёт с
  # `opts[:constraint]` ошибки changeset, куда Ecto пишет error_type (см. `@error_types`).
  @spec normalize_constraint_errors!(term()) :: %{{atom(), atom()} => atom()}

  def normalize_constraint_errors!(raw) when is_list(raw) do
    unless Keyword.keyword?(raw) do
      raise CompileError,
        description: "constraint_errors: ожидается keyword [type: [field: code]]"
    end

    Enum.reduce(raw, %{}, &put_constraint_type/2)
  end

  def normalize_constraint_errors!(other) do
    raise CompileError,
      description: "constraint_errors: ожидается keyword, получено #{inspect(other)}"
  end

  # ---

  defp put_constraint_type({type, fields}, acc) do
    unless type in @constraint_types do
      raise CompileError,
        description:
          "constraint_errors: неизвестный тип #{inspect(type)}, допустимы #{inspect(@constraint_types)}"
    end

    unless is_list(fields) and Keyword.keyword?(fields) do
      raise CompileError,
        description:
          "constraint_errors: для #{inspect(type)} ожидается keyword [field: code], получено #{inspect(fields)}"
    end

    Enum.reduce(fields, acc, &put_constraint_field(type, &1, &2))
  end

  defp put_constraint_field(type, {field, code}, acc) do
    unless is_atom(field) and is_atom(code) do
      raise CompileError,
        description:
          "constraint_errors: field и code должны быть атомами, получено #{inspect({field, code})}"
    end

    key = {Map.fetch!(@error_types, type), field}

    if Map.has_key?(acc, key) do
      raise CompileError, description: "constraint_errors: дубликат #{inspect({type, field})}"
    end

    Map.put(acc, key, code)
  end

  @doc false
  @spec validate_constraint_error_codes!(module(), %{optional(term()) => atom()}) :: :ok

  def validate_constraint_error_codes!(errors, mapping) do
    mapping
    |> Map.values()
    |> Enum.uniq()
    |> Enum.each(&ensure_constraint_error_code!(errors, &1))

    :ok
  end

  # ---

  defp ensure_constraint_error_code!(errors, code) do
    errors.domain(__MODULE__, code, nil)
  rescue
    FunctionClauseError ->
      reraise CompileError,
              [
                description:
                  "constraint_errors: отсутствует clause для #{inspect(code)} в #{inspect(errors)}"
              ],
              __STACKTRACE__
  end

  @doc false
  @spec match_constraint_error(Ecto.Changeset.t(), %{{atom(), atom()} => atom()}) ::
          {:ok, atom(), atom()} | :error

  def match_constraint_error(%Ecto.Changeset{}, mapping) when mapping == %{}, do: :error

  def match_constraint_error(%Ecto.Changeset{errors: errors}, mapping) do
    Enum.find_value(errors, :error, fn
      {field, {_msg, opts}} when is_list(opts) ->
        type = Keyword.get(opts, :constraint)

        case type && Map.fetch(mapping, {type, field}) do
          {:ok, code} -> {:ok, code, field}
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  @doc "Получить сущность по id и version."
  @spec get(map(), term(), Repo.version(), Context.t(), Repo.opts()) ::
          {:ok, struct()} | {:error, Error.t()}

  def get(pg, id, version, context, opts \\ []) do
    db_id = pg.to_id.(id)

    case pg.dao.one(from(x in read_scope(pg, context), where: x.id == ^db_id), opts) do
      nil ->
        {:error, pg.errors.domain(pg.module, :not_found, id)}

      row ->
        case version_error(pg, id, row, version) do
          nil -> {:ok, put_baseline(pg, pg.to_entity.(row), context)}
          error -> {:error, error}
        end
    end
  end

  @doc "Получить сущность; при ошибке — raise."
  @spec get!(map(), term(), Repo.version(), Context.t(), Repo.opts()) :: struct()

  def get!(pg, id, version, context, opts \\ []) do
    Result.unwrap!(get(pg, id, version, context, opts))
  end

  @doc """
  Получить сущность по произвольному фильтру (альтернативный ключ).

  `filter` — `dynamic`, который добавляется к `read_scope` (query + `default_filters`);
  `detail` попадает в `not_found` / `version_mismatch` вместо id.
  """
  @spec get_by(
          map(),
          Ecto.Query.dynamic_expr(),
          term(),
          Repo.version(),
          Context.t(),
          Repo.opts()
        ) :: {:ok, struct()} | {:error, Error.t()}

  def get_by(pg, filter, detail, version, context, opts \\ []) do
    case pg.dao.one(from(x in read_scope(pg, context), where: ^filter), opts) do
      nil ->
        {:error, pg.errors.domain(pg.module, :not_found, detail)}

      row ->
        case version_error(pg, detail, row, version) do
          nil -> {:ok, put_baseline(pg, pg.to_entity.(row), context)}
          error -> {:error, error}
        end
    end
  end

  @doc "Список сущностей в scope."
  @spec list(map(), Context.t(), Repo.opts()) :: [struct()]

  def list(pg, context, opts \\ []) do
    pg.dao.all(read_scope(pg, context), opts)
    |> Enum.map(&put_baseline(pg, pg.to_entity.(&1), context))
  end

  @doc """
  Список сущностей по произвольному фильтру (альтернативный ключ).

  Сиблинг `get_by/6` для выборки пачкой: `filter` — `dynamic`, который добавляется
  к `read_scope` (query + `default_filters`). Отсутствующие ключи просто не попадают
  в результат — это `find`-семантика, не `get`.
  """
  @spec list_by(map(), Ecto.Query.dynamic_expr(), Context.t(), Repo.opts()) :: [struct()]

  def list_by(pg, filter, context, opts \\ []) do
    from(x in read_scope(pg, context), where: ^filter)
    |> then(&pg.dao.all(&1, opts))
    |> Enum.map(&put_baseline(pg, pg.to_entity.(&1), context))
  end

  @doc "Страница сущностей (limit/offset)."
  @spec page(map(), Pagination.Limit.t(), Pagination.Offset.t(), Context.t(), Repo.opts()) ::
          Pagination.Result.t(struct())

  def page(pg, %Pagination.Limit{} = limit, %Pagination.Offset{} = offset, context, opts \\ []) do
    items =
      from(x in read_scope(pg, context),
        limit: ^Pagination.Limit.value(limit),
        offset: ^Pagination.Offset.value(offset)
      )
      |> then(&pg.dao.all(&1, opts))
      |> Enum.map(&put_baseline(pg, pg.to_entity.(&1), context))

    count = pg.dao.aggregate(write_scope(pg, context), :count, opts)

    Pagination.Result.new(items, count)
  end

  @doc "Найти сущности по парам id/version (без incomplete)."
  @spec find_many(map(), [{term(), Repo.version()}], Context.t(), Repo.opts()) ::
          {:ok, [struct()]} | {:error, Error.t()}

  def find_many(pg, pairs, context, opts \\ []) do
    with :ok <- ensure_non_empty(pg, pairs) do
      {resolved, _not_found, _mismatched} =
        fetch_many(pg, pairs, read_scope(pg, context), opts)

      {:ok, Enum.map(resolved, &put_baseline(pg, pg.to_entity.(&1), context))}
    end
  end

  @doc "Получить все сущности по парам id/version."
  @spec get_many(map(), [{term(), Repo.version()}], Context.t(), Repo.opts()) ::
          {:ok, [struct()]} | {:error, Error.t()}

  def get_many(pg, pairs, context, opts \\ []) do
    with :ok <- ensure_non_empty(pg, pairs) do
      case fetch_many(pg, pairs, read_scope(pg, context), opts) do
        {resolved, [], []} ->
          {:ok, Enum.map(resolved, &put_baseline(pg, pg.to_entity.(&1), context))}

        {_resolved, not_found, mismatched} ->
          {:error,
           pg.errors.domain(pg.module, :incomplete_result, %{
             not_found: not_found,
             version_mismatch: mismatched
           })}
      end
    end
  end

  @doc "Проверить существование по id и version."
  @spec exists?(map(), term(), Repo.version(), Context.t(), Repo.opts()) ::
          {:ok, boolean()} | {:error, Error.t()}

  def exists?(pg, id, version, context, opts \\ [])

  def exists?(pg, id, :current, context, opts) when is_list(opts) do
    db_id = pg.to_id.(id)
    {:ok, pg.dao.exists?(from(x in write_scope(pg, context), where: x.id == ^db_id), opts)}
  end

  def exists?(pg, id, %Version{} = version, context, opts) when is_list(opts) do
    db_id = pg.to_id.(id)

    case pg.dao.one(from(x in write_scope(pg, context), where: x.id == ^db_id), opts) do
      nil ->
        {:ok, false}

      row ->
        case version_error(pg, id, row, version) do
          nil -> {:ok, true}
          error -> {:error, error}
        end
    end
  end

  @doc "Проверить существование всех пар id/version."
  @spec exists_all?(map(), [{term(), Repo.version()}], Context.t(), Repo.opts()) ::
          {:ok, boolean()} | {:error, Error.t()}

  def exists_all?(pg, pairs, context, opts \\ []) do
    with :ok <- ensure_non_empty(pg, pairs) do
      case fetch_many(pg, pairs, write_scope(pg, context), opts) do
        {_resolved, not_found, []} ->
          {:ok, not_found == []}

        {_resolved, _not_found, mismatched} ->
          {:error, pg.errors.domain(pg.module, :version_mismatch, mismatched)}
      end
    end
  end

  @doc "Число сущностей в scope."
  @spec count(map(), Context.t(), Repo.opts()) :: non_neg_integer()

  def count(pg, context, opts \\ []),
    do: pg.dao.aggregate(write_scope(pg, context), :count, opts)

  @doc "Вставить сущность."
  @spec insert(map(), struct(), Context.t(), Repo.opts()) ::
          {:ok, struct()} | {:error, Error.t()} | {:error, Ecto.Changeset.t()}

  def insert(pg, entity, context, opts \\ []) do
    case raw_insert(pg, entity, context, opts) do
      {:ok, row} -> {:ok, pg.to_entity.(row)}
      {:error, _} = error -> error
    end
  end

  @doc "Обновить сущность."
  @spec update(map(), struct(), Context.t(), Repo.opts()) ::
          {:ok, struct()} | {:error, Error.t()} | {:error, Ecto.Changeset.t()}

  def update(pg, entity, context, opts \\ []) do
    case raw_update(pg, entity, context, opts) do
      {:ok, row} -> {:ok, pg.to_entity.(row)}
      :unchanged -> {:ok, entity}
      {:error, _} = error -> error
    end
  end

  @doc """
  Вставить сущность без декодирования результата обратно в domain — для `Repo.Pg.Es`.

  Возвращаемая `Repo.Pg.insert/4`/`update/4` сущность там всё равно отбрасывается (агрегат
  с детьми и событиями возвращает входной `entity`, см. `Repo.Pg.Es`), а строка сразу после
  `insert` содержит непрогруженные `has_many` — decode мог бы упасть на доменной валидации
  (например «список шагов не может быть пустым»), хотя сама запись прошла успешно.
  """
  @spec write_insert(map(), struct(), Context.t(), Repo.opts()) ::
          :ok | {:error, Error.t()} | {:error, Ecto.Changeset.t()}

  def write_insert(pg, entity, context, opts \\ []) do
    case raw_insert(pg, entity, context, opts) do
      {:ok, _row} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Вставить пачку сущностей одним `insert_all`; вернуть число записанных строк.

  Для массовой первичной загрузки: строки собираются через `to_model` и `changeset/2`
  (нужен cast wire-значений в типы колонок — `insert_all` их не приводит), после чего
  пишутся без построчного `SELECT` и без декодирования обратно в domain.

  `on_conflict: :nothing` по **любому** уникальному ограничению таблицы: повторный
  прогон той же выгрузки — no-op, а не падение. Обновлять существующие строки этот
  путь не умеет **намеренно** — изменение состояния идёт через `update/4` под
  проверкой версии.

  Эталон в `Repo.Sc` не кладётся: пачка не читалась, сверять её не с чем.
  """
  @spec insert_many(map(), [struct()], Context.t(), Repo.opts()) :: non_neg_integer()

  def insert_many(pg, entities, context, opts \\ [])

  def insert_many(_pg, [], %Context{}, opts) when is_list(opts), do: 0

  def insert_many(pg, entities, %Context{}, opts) when is_list(entities) and is_list(opts) do
    {chunk_size, query_opts} = Keyword.pop(opts, :chunk_size, @insert_many_chunk_size)

    entities
    |> Enum.chunk_every(chunk_size)
    |> Enum.reduce(0, fn chunk, acc -> acc + insert_chunk(pg, chunk, query_opts) end)
  end

  @doc "Обновить сущность без декодирования результата обратно в domain — см. `write_insert/4`."
  @spec write_update(map(), struct(), Context.t(), Repo.opts()) ::
          :ok | {:error, Error.t()} | {:error, Ecto.Changeset.t()}

  def write_update(pg, entity, context, opts \\ []) do
    case raw_update(pg, entity, context, opts) do
      {:ok, _row} -> :ok
      :unchanged -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "Удалить сущность по id и version."
  @spec delete(map(), term(), Repo.version(), Context.t(), Repo.opts()) ::
          :ok | {:error, Error.t()}

  def delete(pg, id, version, context, opts \\ []) do
    db_id = pg.to_id.(id)
    scope = from(x in write_scope(pg, context), where: x.id == ^db_id)

    case pg.dao.one(scope, opts) do
      nil ->
        {:error, pg.errors.domain(pg.module, :not_found, id)}

      row ->
        case version_error(pg, id, row, version) do
          nil -> delete_scope(pg, id, versioned_scope(pg, scope, version), version, opts)
          error -> {:error, error}
        end
    end
  end

  @doc "Сохранить сущность (insert или update)."
  @spec save(map(), struct(), Context.t(), Repo.opts()) ::
          {:ok, struct()} | {:error, Error.t()} | {:error, Ecto.Changeset.t()}

  def save(pg, entity, context, opts \\ []) do
    case known_to_exist?(pg, entity, context, opts) do
      {:ok, true} -> update(pg, entity, context, opts)
      {:ok, false} -> insert(pg, entity, context, opts)
    end
  end

  @doc "Ошибка несовпадения версии строки с ожидаемой, либо `nil`."
  @spec version_error(map(), term(), struct(), Repo.version()) :: Error.t() | nil

  def version_error(pg, id, row, version) do
    if version_matches?(pg, row, version) do
      nil
    else
      actual = Map.fetch!(row, pg.version_field)

      pg.errors.domain(pg.module, :version_mismatch, %{
        id: id,
        expected: version,
        actual: actual
      })
    end
  end

  @doc """
  Scope чтения: `query:` под `default_filters:`.

  Публичен, потому что кастомные методы репозитория (выборка по альтернативному ключу,
  агрегаты) обязаны строить запрос **поверх** него: собранный мимо scope запрос молча
  обходит `default_filters` — то есть soft-delete и ACL-фильтры.
  """
  @spec read_scope(map(), Context.t()) :: Ecto.Query.t()

  def read_scope(%{query: query, default_filters: default_filters}, context) do
    from(x in query, where: ^default_filters.(context))
  end

  @doc """
  Эталон сущности из `Repo.Sc` — состояние на момент последнего чтения или успешной записи.

  `nil` при `shadow_copy?: false`, при выключенном кэше и когда эталон ещё не положен.
  """
  @spec baseline(map(), struct(), Context.t()) :: struct() | nil

  def baseline(%{shadow_copy?: false}, _entity, _context), do: nil
  def baseline(%{shadow_copy?: true}, %mod{id: id}, context), do: Repo.Sc.fetch(context, mod, id)

  @doc """
  Положить сущность эталоном в `Repo.Sc` и вернуть её.

  No-op при `shadow_copy?: false`.
  """
  @spec put_baseline(map(), struct(), Context.t()) :: struct()

  def put_baseline(%{shadow_copy?: false}, entity, _context), do: entity
  def put_baseline(%{shadow_copy?: true}, entity, context), do: Repo.Sc.put(context, entity)

  # ---

  defp raw_insert(pg, entity, _context, opts) do
    changeset = pg.schema.changeset(struct(pg.schema), pg.to_model.(entity))

    case pg.dao.insert(changeset, opts) do
      {:ok, row} -> {:ok, row}
      {:error, %Ecto.Changeset{} = failed} -> map_constraint_error(pg, failed, entity)
    end
  end

  # Состояние совпало с эталоном — писать нечего, но «успех» без запроса скрыл бы
  # удаление строки после чтения, ACL-скоуп и расхождение версии: проверяем их SELECT'ом
  # в том же write_scope, что и обычный UPDATE.
  defp raw_update(pg, entity, context, opts) do
    if baseline(pg, entity, context) == entity,
      do: verify_unchanged(pg, entity, context, opts),
      else: do_raw_update(pg, entity, context, opts)
  end

  defp verify_unchanged(pg, entity, context, opts) do
    db_id = pg.to_id.(entity.id)

    case pg.dao.one(from(x in write_scope(pg, context), where: x.id == ^db_id), opts) do
      nil -> {:error, pg.errors.domain(pg.module, :not_found, entity.id)}
      base -> unchanged_or_stale(pg, entity, base, context)
    end
  end

  defp unchanged_or_stale(pg, entity, base, context) do
    case stale_error(pg, entity, base, context) do
      nil -> :unchanged
      error -> {:error, error}
    end
  end

  defp do_raw_update(pg, entity, context, opts) do
    attrs = pg.to_model.(entity)

    case pg.dao.one(from(x in write_scope(pg, context), where: x.id == ^attrs.id), opts) do
      nil -> {:error, pg.errors.domain(pg.module, :not_found, entity.id)}
      base -> update_checked(pg, entity, base, attrs, context, opts)
    end
  end

  # Две разные гонки: чужой commit между чтением агрегата доменом и этой записью ловится
  # сверкой с эталоном `Repo.Sc`, чужой commit между этим SELECT и UPDATE — фильтром по
  # прочитанной версии (иначе UPDATE ... WHERE id = ? затёр бы его молча).
  defp update_checked(pg, entity, base, attrs, context, opts) do
    case stale_error(pg, entity, base, context) do
      nil ->
        changeset = lock_version(pg, pg.schema.changeset(base, attrs), base)
        persist_update(pg, entity, changeset, opts)

      error ->
        {:error, error}
    end
  end

  defp stale_error(pg, entity, base, context) do
    case baseline(pg, entity, context) do
      nil -> nil
      baseline -> expected_version_error(pg, entity, base, Map.get(baseline, pg.version_field))
    end
  end

  defp expected_version_error(pg, entity, base, %Version{} = expected) do
    if Map.has_key?(base, pg.version_field),
      do: version_error(pg, entity.id, base, expected),
      else: nil
  end

  defp expected_version_error(_pg, _entity, _base, _absent), do: nil

  defp lock_version(pg, %Ecto.Changeset{} = changeset, base) do
    case Map.get(base, pg.version_field) do
      nil -> changeset
      current -> %{changeset | filters: Map.put(changeset.filters, pg.version_field, current)}
    end
  end

  defp persist_update(pg, entity, changeset, opts) do
    case pg.dao.update(changeset, opts) do
      {:ok, row} ->
        {:ok, row}

      {:error, %Ecto.Changeset{} = failed} ->
        map_constraint_error(pg, failed, entity)
    end
  rescue
    Ecto.StaleEntryError ->
      detail = %{id: entity.id, expected: Map.get(entity, pg.version_field), actual: :stale}
      {:error, pg.errors.domain(pg.module, :version_mismatch, detail)}
  end

  # Версия проверена по прочитанной строке, но между SELECT и DELETE могла пройти
  # конкурентная запись: без предиката в самом DELETE она была бы затёрта молча.
  defp versioned_scope(_pg, scope, :current), do: scope

  defp versioned_scope(pg, scope, %Version{} = version) do
    expected = Version.value(version)
    from(x in scope, where: field(x, ^pg.version_field) == ^expected)
  end

  defp delete_scope(pg, id, scope, version, opts) do
    case pg.dao.delete_all(scope, opts) do
      {0, _} -> {:error, delete_miss_error(pg, id, version)}
      {_deleted, _} -> :ok
    end
  end

  defp delete_miss_error(pg, id, :current), do: pg.errors.domain(pg.module, :not_found, id)

  defp delete_miss_error(pg, id, %Version{} = version) do
    pg.errors.domain(pg.module, :version_mismatch, %{id: id, expected: version, actual: :stale})
  end

  defp map_constraint_error(pg, changeset, entity) do
    case match_constraint_error(changeset, pg.constraint_errors) do
      {:ok, code, field} ->
        {:error, pg.errors.domain(pg.module, code, constraint_input(entity, changeset, field))}

      :error ->
        {:error, changeset}
    end
  end

  defp constraint_input(entity, changeset, field) do
    case Map.fetch(entity, field) do
      {:ok, value} -> value
      :error -> Ecto.Changeset.get_field(changeset, field)
    end
  end

  defp fetch_many(pg, pairs, scope, opts) do
    db_ids =
      pairs
      |> Enum.map(fn {id, _version} -> pg.to_id.(id) end)
      |> Enum.uniq()

    rows_by_db_id =
      pg.dao.all(from(x in scope, where: x.id in ^db_ids), opts)
      |> Map.new(&{&1.id, &1})

    {resolved, not_found, mismatched} =
      Enum.reduce(pairs, {[], [], []}, &accumulate_pair(pg, &1, &2, rows_by_db_id))

    {Enum.reverse(resolved), Enum.reverse(not_found), Enum.reverse(mismatched)}
  end

  defp accumulate_pair(pg, {id, version}, {resolved, not_found, mismatched}, rows_by_db_id) do
    case Map.fetch(rows_by_db_id, pg.to_id.(id)) do
      :error ->
        {resolved, [id | not_found], mismatched}

      {:ok, row} ->
        if version_matches?(pg, row, version) do
          {[row | resolved], not_found, mismatched}
        else
          actual = Map.fetch!(row, pg.version_field)
          {resolved, not_found, [%{id: id, expected: version, actual: actual} | mismatched]}
        end
    end
  end

  # `ON CONFLICT DO NOTHING` без `conflict_target` покрывает **любое** уникальное
  # ограничение таблицы, а не только первичный ключ. Это существенно там, где
  # идентичность агрегата генерируется, а естественный ключ живёт в отдельном
  # уникальном индексе: повторная строка конфликтует по нему, а не по `id`.
  defp insert_chunk(pg, chunk, opts) do
    rows = Enum.map(chunk, &insert_many_row(pg, &1))
    {count, _} = pg.dao.insert_all(pg.schema, rows, [on_conflict: :nothing] ++ opts)

    count
  end

  # `insert_all` не приводит значения к типам колонок, а `to_model` отдаёт wire-формат
  # (строки uuid, `%Date{}` внутри jsonb). Прогон через changeset переиспользует тот же
  # cast, что и построчный `insert/4`, — иначе два пути записи разошлись бы по формату.
  defp insert_many_row(pg, entity) do
    pg.schema
    |> struct()
    |> pg.schema.changeset(pg.to_model.(entity))
    |> Ecto.Changeset.apply_action!(:insert)
    |> Map.take(insert_many_fields(pg))
  end

  defp insert_many_fields(pg) do
    :fields
    |> pg.schema.__schema__()
    |> Enum.reject(&(&1 in pg.schema.__schema__(:virtual_fields)))
  end

  defp write_scope(pg, context) do
    pg
    |> read_scope(context)
    |> exclude(:order_by)
    |> exclude(:preload)
    |> exclude(:select)
  end

  defp known_to_exist?(pg, entity, context, opts) do
    if baseline(pg, entity, context) != nil,
      do: {:ok, true},
      else: exists?(pg, entity.id, :current, context, opts)
  end

  defp version_matches?(_pg, _row, :current), do: true

  defp version_matches?(pg, row, %Version{} = expected),
    do: Map.fetch!(row, pg.version_field) == Version.value(expected)

  defp ensure_non_empty(pg, []) do
    {:error, pg.errors.domain(pg.module, :no_ids, [])}
  end

  defp ensure_non_empty(_pg, _pairs), do: :ok
end
