defmodule Core.Repo.ConstraintErrorsCase do
  @moduledoc """
  Case-модуль сверки `constraint_errors:` репозиториев приложения с `changeset/2` и с БД.

      defmodule MyApp.Repo.ConstraintErrorsTest do
        use Core.Repo.ConstraintErrorsCase,
          otp_app: :my_app,
          async: true
      end

  Один тест-модуль на приложение поверх `ExUnit.Case` со своим sandbox checkout на
  `Core.Config.dao/0`. Маппинг, который не может сработать, при записи не падает: наружу уходит
  прикладной `%Core.Error{kind: :app, code: :write_failed}` (у дочерней таблицы — голый
  `Postgrex.Error`) вместо доменного кода с текстом для клиента. Поэтому декларации сверяются
  с `changeset/2` и с БД тестом на все репозитории, а не ревью.

  Репозитории — модули `otp_app:` (`Application.spec/2`) с `__constraint_errors__/0`: его
  генерирует каждый `use Core.Repo.Pg`, а дочерние таблицы отдаёт
  `__children_constraint_errors__/0` у `use Core.Repo.Pg.StateStored`. Перечня нет: новый
  репозиторий попадает под проверку сам. Write-репозиторий — модуль с любым из
  `Core.Repo.write_methods/0` (`insert/3` / `update/3` / `save/3`): маппинг срабатывает только на
  записи, а у схемы read-репозитория `changeset/2` нет (`13-repos.md`).

  ## Генерируемые тесты

  1. каждый ключ `constraint_errors:` write-репозитория объявлен в `changeset/2` его схемы;
     сверка по `{error_type, поле}`, а не по типу ограничения: `foreign_key:` сверяется
     с `:foreign` (`Core.Repo.Pg`);
  2. каждое ограничение `changeset/2` покрыто маппингом;
  3. имена ограничений `changeset/2` и ключи `constraint_errors:` в `children:` есть у своей
     таблицы — `pg_constraint` плюс имена индексов: `unique_index` строки в `pg_constraint`
     не создаёт;
  4. каждый FK дочерней таблицы покрыт маппингом, кроме FK ровно по колонке `fk:` — на сам
     агрегат: строка родителя пишется той же транзакцией раньше, нарушить его нечем;
  5. read-репозиторий `constraint_errors:` не объявляет: маппинг срабатывает только на записи.

  `changeset/2` вызывается на пустой структуре схемы с пустыми атрибутами: ограничение,
  которое добавляется по условию на атрибуты, проверке не видно. Сверки 3 и 4 читают каталог
  через `Core.Config.dao/0` по имени таблицы без префикса: write-репозиторий со своим `repo:` или
  схема с `@schema_prefix` дадут ложный провал имён и холостую сверку FK.

  Логика теста — функция `check_*` (`:ok | {:error, detail}`), сам тест — `assert :ok = …`:
  провал печатает репозитории и расхождения.

  ## Opts

  - `otp_app:` — приложение, чьи модули проверяются; не загружено или в нём нет ни одного
    репозитория — провал всех тестов модуля
  - `async:` — опция `ExUnit.Case`, необязательная, по умолчанию `true`; явное значение требует
    `Credo.Check.Refactor.PassAsyncInTestCases`
  """

  alias Core.Helper
  alias Core.Repo

  @label "Repo.ConstraintErrorsCase"
  @required_keys ~w(otp_app)a
  @optional_keys ~w(async)a

  @constraint_names_sql """
  SELECT conname::text FROM pg_constraint WHERE conrelid = to_regclass($1)
  UNION
  SELECT ic.relname::text
    FROM pg_index i
    JOIN pg_class ic ON ic.oid = i.indexrelid
   WHERE i.indrelid = to_regclass($1)
  """

  @foreign_keys_sql """
  SELECT c.conname::text,
         ARRAY(SELECT a.attname::text
                 FROM unnest(c.conkey) AS k(attnum)
                 JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum)
    FROM pg_constraint c
   WHERE c.conrelid = to_regclass($1) AND c.contype = 'f'
  """

  @typedoc "Ключ маппинга и ограничения `changeset/2`: `{error_type, поле}`."
  @type key :: {atom(), atom()}

  @typedoc "Ключи маппинга, которых нет в `changeset/2`."
  @type undeclared :: %{undeclared: [{module(), key()}]}

  @typedoc "Ограничения `changeset/2` без маппинга."
  @type unmapped :: %{unmapped: [{module(), key()}]}

  @typedoc "Имена ограничений, которых нет у таблицы: репозиторий, таблица, имя."
  @type missing :: %{missing: [{module(), String.t(), String.t()}]}

  @typedoc "FK дочерних таблиц без маппинга: репозиторий, таблица, имя."
  @type unmapped_foreign_keys :: %{unmapped_foreign_keys: [{module(), String.t(), String.t()}]}

  @typedoc "Read-репозитории с `constraint_errors:`."
  @type mapped :: %{mapped: [module()]}

  # ===== объявление =====

  @doc "Сгенерировать тесты сверки `constraint_errors:` репозиториев приложения."
  defmacro __using__(opts) do
    lit = Macro.expand_literals(opts, __CALLER__)
    Helper.Opts.validate!(lit, @required_keys, @optional_keys, @label)
    otp_app = Helper.Opts.atom!(lit, :otp_app, @label)
    async = async!(lit)

    quote do
      use ExUnit.Case, async: unquote(async)

      setup_all do
        %{repos: Core.Repo.ConstraintErrorsCase.repos!(unquote(otp_app))}
      end

      setup do
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Core.Config.dao())
      end

      test "каждый ключ constraint_errors объявлен в changeset/2", %{repos: repos} do
        assert :ok = Core.Repo.ConstraintErrorsCase.check_mapping_declared(repos)
      end

      test "каждое ограничение changeset/2 покрыто constraint_errors", %{repos: repos} do
        assert :ok = Core.Repo.ConstraintErrorsCase.check_constraints_mapped(repos)
      end

      test "имена ограничений changeset/2 и children: существуют в БД", %{repos: repos} do
        assert :ok = Core.Repo.ConstraintErrorsCase.check_constraint_names(repos, Core.Config.dao())
      end

      test "каждый FK дочерней таблицы, кроме fk: на агрегат, покрыт constraint_errors", %{repos: repos} do
        assert :ok = Core.Repo.ConstraintErrorsCase.check_children_foreign_keys(repos, Core.Config.dao())
      end

      test "read-репозиторий не объявляет constraint_errors", %{repos: repos} do
        assert :ok = Core.Repo.ConstraintErrorsCase.check_read_repos(repos)
      end
    end
  end

  # ---

  defp async!(opts) do
    case Keyword.get(opts, :async, true) do
      async when is_boolean(async) ->
        async

      other ->
        raise CompileError,
          description: "#{@label}: async: ожидается boolean, получено #{inspect(other)}"
    end
  end

  # ===== репозитории =====

  @doc false
  @spec repos!(atom()) :: [module(), ...]

  def repos!(otp_app) when is_atom(otp_app) do
    with modules when is_list(modules) <- Application.spec(otp_app, :modules),
         [_ | _] = repos <- Enum.filter(modules, &exports?(&1, :__constraint_errors__, 0)) do
      repos
    else
      nil -> raise ArgumentError, "#{@label}: приложение #{inspect(otp_app)} не загружено"
      [] -> raise ArgumentError, "#{@label}: в приложении #{inspect(otp_app)} нет репозиториев"
    end
  end

  # ===== ключи маппинга =====

  @doc false
  @spec check_mapping_declared([module()]) :: :ok | {:error, undeclared()}

  def check_mapping_declared(repos) when is_list(repos) do
    repos
    |> write_repos()
    |> Enum.flat_map(&undeclared_keys/1)
    |> result(:undeclared)
  end

  # ---

  defp undeclared_keys(repo) do
    {schema, mapping} = repo.__constraint_errors__()
    declared = MapSet.new(changeset_constraints(schema), &{&1.error_type, &1.field})

    for key <- Map.keys(mapping), key not in declared, do: {repo, key}
  end

  # ===== покрытие changeset/2 =====

  @doc false
  @spec check_constraints_mapped([module()]) :: :ok | {:error, unmapped()}

  def check_constraints_mapped(repos) when is_list(repos) do
    repos
    |> write_repos()
    |> Enum.flat_map(&unmapped_keys/1)
    |> result(:unmapped)
  end

  # ---

  defp unmapped_keys(repo) do
    {schema, mapping} = repo.__constraint_errors__()

    for %{error_type: type, field: field} <- changeset_constraints(schema),
        not is_map_key(mapping, {type, field}),
        do: {repo, {type, field}}
  end

  # ===== имена в БД =====

  @doc false
  @spec check_constraint_names([module()], module()) :: :ok | {:error, missing()}

  def check_constraint_names(repos, dao) when is_list(repos) and is_atom(dao) do
    repos
    |> write_repos()
    |> Enum.flat_map(&(missing_names(&1, dao) ++ missing_child_names(&1, dao)))
    |> result(:missing)
  end

  # ---

  defp missing_names(repo, dao) do
    {schema, _mapping} = repo.__constraint_errors__()
    table = schema.__schema__(:source)
    names = constraint_names(dao, table)

    for %{constraint: name} <- changeset_constraints(schema), name not in names, do: {repo, table, name}
  end

  defp missing_child_names(repo, dao) do
    Enum.flat_map(children(repo), fn spec ->
      table = spec.schema.__schema__(:source)
      names = constraint_names(dao, table)

      for name <- Map.keys(spec.constraint_errors), name not in names, do: {repo, table, name}
    end)
  end

  defp constraint_names(dao, table) do
    dao
    |> query(@constraint_names_sql, table)
    |> MapSet.new(fn [name] -> name end)
  end

  # ===== FK дочерних таблиц =====

  @doc false
  @spec check_children_foreign_keys([module()], module()) :: :ok | {:error, unmapped_foreign_keys()}

  def check_children_foreign_keys(repos, dao) when is_list(repos) and is_atom(dao) do
    repos
    |> write_repos()
    |> Enum.flat_map(&unmapped_foreign_keys(&1, dao))
    |> result(:unmapped_foreign_keys)
  end

  # ---

  defp unmapped_foreign_keys(repo, dao) do
    Enum.flat_map(children(repo), fn spec ->
      table = spec.schema.__schema__(:source)
      fk = [Atom.to_string(spec.fk)]

      for [name, columns] <- query(dao, @foreign_keys_sql, table),
          columns != fk,
          not is_map_key(spec.constraint_errors, name),
          do: {repo, table, name}
    end)
  end

  # ===== read-репозитории =====

  @doc false
  @spec check_read_repos([module()]) :: :ok | {:error, mapped()}

  def check_read_repos(repos) when is_list(repos) do
    repos
    |> Enum.filter(&mapped_read?/1)
    |> result(:mapped)
  end

  # ---

  defp mapped_read?(repo) do
    {_schema, mapping} = repo.__constraint_errors__()
    map_size(mapping) > 0 and not write?(repo)
  end

  # ===== общее =====

  defp write_repos(repos), do: Enum.filter(repos, &write?/1)

  defp write?(repo), do: Enum.any?(Repo.write_methods(), &exports?(repo, &1, 3))

  defp children(repo) do
    if exports?(repo, :__children_constraint_errors__, 0),
      do: repo.__children_constraint_errors__(),
      else: []
  end

  # `function_exported?/3` не грузит модуль: ещё не загруженный репозиторий иначе выпал бы из сверки молча.
  defp exports?(module, name, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, name, arity)

  defp changeset_constraints(schema) do
    schema
    |> struct()
    |> schema.changeset(%{})
    |> Map.fetch!(:constraints)
  end

  defp query(dao, sql, table) do
    %Postgrex.Result{rows: rows} = Ecto.Adapters.SQL.query!(dao, sql, [table])
    rows
  end

  defp result([], _key), do: :ok

  defp result(found, key) do
    sorted =
      found
      |> Enum.uniq()
      |> Enum.sort()

    {:error, %{key => sorted}}
  end
end
