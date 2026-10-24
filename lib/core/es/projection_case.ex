defmodule Core.Es.ProjectionCase do
  @moduledoc """
  Case-модуль проекции: очистка `clear/0` и ПДн read-модели на golden-фикстурах событий.

      defmodule MyApp.Domain.<BC>.AccountList.ProjectionCaseTest do
        use Core.Es.ProjectionCase,
          projection: MyApp.Domain.<BC>.AccountList.Projection,
          async: false
      end

  Один тест-модуль на проекцию поверх `ExUnit.Case, async: false` со своим sandbox checkout на
  `repo:` проекции (по умолчанию `Core.Config.dao/0`): `TRUNCATE` в `clear/0` держит
  `ACCESS EXCLUSIVE` до конца sandbox-транзакции.

  Фикстура модуля из `events:` — `<тип агрегата>/<текущий тег>.json` от корня `fixtures:`; тип
  агрегата и тег берутся из кодека события, фикстуру грузит он же с фасадом `codec:` проекции. Тег в
  `type` фикстуры сверяется с текущим: фикстуры источников `upcasts:` не прогоняются, апкаст
  проверяет `Core.Es.EventCompatCase`. Нет фикстуры, в ней чужой тег или она не грузится — провал
  теста с путями. Событие уничтожения ключа `Core.Es.Personal.Event.KeyDestroyed` case строит сам
  (`Core.Es.Personal.Test.key_destroyed/2`), его фикстура не ищется.

  ## Генерируемые тесты

  ### Очистка

  `clear/0` очищает каждую таблицу, которую пишет `project/1`: `project/1` на всех фикстурах,
  каждая в savepoint (отказ откатывается), затем `clear/0` и `count(*) = 0` у каждой таблицы, в
  которой `n_tup_ins + n_tup_upd + n_tup_del` из `pg_stat_xact_user_tables` вырос за прогон.
  Перечня таблиц нет: внутри открытой транзакции статистика не сбрасывается и считает попытки
  откаченных savepoint'ов, разница точна. Ни одной таблицы — провал. Таблица, в которой
  `project/1` на фикстурах не изменил ни строки (`UPDATE` строки, которой нет, `INSERT`,
  отвергнутый ограничением), в набор не попадает.

  ### Уничтоженное ПДн-значение

  На каждой фикстуре события с полями `subject:` — `project/1` на её уничтоженном варианте
  (`Core.Es.Personal.Test.destroyed/2`), затем на открытой, каждый в savepoint с откатом. Открытый
  прошёл, а уничтоженный дал исключение или `{:error, _}` — провал с путём фикстуры и причиной.

  ### ПДн после уничтожения ключа

  На каждой фикстуре события с полями `subject:`, в savepoint с откатом: `project/1` на фикстуре,
  затем на событии уничтожения ключа каждого её субъекта, затем поиск открытых строковых
  wire-значений ПДн-полей фикстуры в строках таблиц, которые изменил прогон. У проекции с
  `personal: false` события уничтожения ключа нет, и поиск идёт сразу после фикстуры. Находка —
  провал с путём фикстуры, таблицей, колонкой и полем нагрузки; отказ `project/1` на событии
  уничтожения ключа — провал с причиной. Фикстура, на которой отказал сам `project/1`, пропускается.

  Поиск находит строку целиком и её вхождение в текстовой колонке и в `jsonb`; значение, изменённое
  перед записью (нижний регистр, склейка частей, хеш), и не строковые значения он не видит.

  Полноту `project/1` проверяет сборка проекции (`Core.Es.Projection`, «Полнота `project/1`»).

  Логика тестов — функции `check_clear/2`, `check_destroyed/2` и `check_personal/2`
  (`:ok | {:error, detail}`) в транзакции с откатом, сами тесты — `assert :ok = …`.

  ## Opts

  - `projection:` — модуль `use Core.Es.Projection`
  - `fixtures:` — корень фикстур от корня проекта, необязательная; по умолчанию
    `test/support/fixtures/events`
  - `async:` — только `false`, необязательная; явное значение требует
    `Credo.Check.Refactor.PassAsyncInTestCases`
  """

  alias Core.Es.Personal
  alias Core.Es.Personal.ActorID
  alias Core.Es.Personal.Event.KeyDestroyed
  alias Core.Es.Personal.Marker
  alias Core.Es.Personal.SubjectID
  alias Core.Helper
  alias Core.Helper.Savepoint
  alias Core.Helper.Transact
  alias Core.Result

  @label "Es.ProjectionCase"
  @required_keys ~w(projection)a
  @optional_keys ~w(async fixtures)a
  @expression_keys ~w()a
  @fixtures_root "test/support/fixtures/events"

  @table_writes_sql """
  SELECT schemaname, relname, n_tup_ins + n_tup_upd + n_tup_del FROM pg_stat_xact_user_tables
  """

  @typedoc "Модули `events:` без фикстуры: путь и модуль."
  @type missing :: %{missing: [{Path.t(), module()}]}

  @typedoc "Фикстуры, которые не загрузились, с причиной."
  @type failed :: %{failed: [{Path.t(), reason()}]}

  @typedoc """
  Причина: файл не читается, не JSON, тег в конверте (`type`) — не текущий тег модуля или ошибка
  загрузки.
  """
  @type reason :: File.posix() | Jason.DecodeError.t() | %{type: term()} | Core.Error.t()

  @typedoc """
  Отказ `clear/0`, пустой набор таблиц или таблицы (`схема.имя`) со строками после `clear/0`.
  """
  @type uncleared ::
          %{clear: Core.Error.t()}
          | %{tables: []}
          | %{not_cleared: [{String.t(), pos_integer()}]}

  @typedoc "Фикстуры, на уничтоженном варианте которых `project/1` отказал, с причиной."
  @type destroyed_failed :: %{destroyed_failed: [{Path.t(), term()}]}

  @typedoc """
  Отказ `project/1` на событии уничтожения ключа или открытые ПДн после него: таблица
  (`схема.имя`), колонка и поле нагрузки.
  """
  @type personal_left ::
          %{key_destroyed_failed: [{Path.t(), term()}]}
          | %{personal_left: [{Path.t(), [{String.t(), String.t(), atom()}]}]}

  # ===== объявление =====

  @doc "Сгенерировать тесты очистки `clear/0` и ПДн read-модели проекции."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)
    projection = Helper.Opts.module!(opts, :projection, @label, exports: [__es_projection__: 0])
    fixtures = fixtures!(opts)
    :ok = ensure_sync!(opts)

    quote do
      use ExUnit.Case, async: false

      setup do
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(unquote(projection).__es_projection__().dao)
      end

      test "clear/0 очищает каждую таблицу, которую пишет project/1" do
        assert :ok = Core.Es.ProjectionCase.check_clear(unquote(projection), unquote(fixtures))
      end

      test "project/1 принимает уничтоженное ПДн-значение" do
        assert :ok = Core.Es.ProjectionCase.check_destroyed(unquote(projection), unquote(fixtures))
      end

      test "после события уничтожения ключа в read-модели нет открытого ПДн" do
        assert :ok = Core.Es.ProjectionCase.check_personal(unquote(projection), unquote(fixtures))
      end
    end
  end

  # ---

  defp fixtures!(opts) do
    case Keyword.get(opts, :fixtures, @fixtures_root) do
      fixtures when is_binary(fixtures) and fixtures != "" ->
        fixtures

      other ->
        Helper.Opts.reject!(
          "#{@label}: fixtures",
          "ожидается непустая строка — корень фикстур, получено #{inspect(other)}"
        )
    end
  end

  defp ensure_sync!(opts) do
    case Keyword.get(opts, :async, false) do
      false ->
        :ok

      other ->
        Helper.Opts.reject!(
          "#{@label}: async",
          "допускается только false — TRUNCATE в clear/0 держит блокировку до конца sandbox, " <>
            "получено #{inspect(other)}"
        )
    end
  end

  # ===== полнота clear =====

  @doc false
  @spec check_clear(module(), Path.t()) :: Result.unit(missing() | failed() | uncleared())

  def check_clear(projection, fixtures) when is_atom(projection) and is_binary(fixtures) do
    %{dao: dao} = declaration = projection.__es_projection__()

    with {:ok, loaded} <- load_fixtures(declaration, fixtures) do
      rolled_back(dao, fn -> check_tables(projection, dao, loaded) end)
    end
  end

  # ---

  defp check_tables(projection, dao, loaded) do
    with {:ok, tables} <- written_tables(projection, dao, loaded),
         :ok <- check_clear_result(projection.clear()) do
      check_empty(dao, tables)
    end
  end

  defp written_tables(projection, dao, loaded) do
    before = table_writes(dao)

    Enum.each(loaded, fn {_path, event} ->
      Savepoint.run(dao, fn -> project_or_error(projection, event) end)
    end)

    case written(before, table_writes(dao)) do
      [] -> {:error, %{tables: []}}
      tables -> {:ok, tables}
    end
  end

  defp check_clear_result(:ok), do: :ok
  defp check_clear_result({:error, error}), do: {:error, %{clear: error}}

  defp check_empty(dao, tables) do
    tables
    |> Enum.map(fn {schema, table} ->
      {"#{schema}.#{table}", dao.aggregate(table, :count, prefix: schema)}
    end)
    |> Enum.reject(&match?({_table, 0}, &1))
    |> case do
      [] -> :ok
      not_cleared -> {:error, %{not_cleared: not_cleared}}
    end
  end

  # ===== уничтоженное значение =====

  @doc false
  @spec check_destroyed(module(), Path.t()) :: Result.unit(missing() | failed() | destroyed_failed())

  def check_destroyed(projection, fixtures) when is_atom(projection) and is_binary(fixtures) do
    %{dao: dao, codec: codec} = declaration = projection.__es_projection__()

    with {:ok, loaded} <- load_fixtures(declaration, fixtures) do
      rolled_back(dao, fn ->
        loaded
        |> personal_fixtures(codec)
        |> Enum.flat_map(&destroyed_failure(projection, dao, &1))
        |> destroyed_result()
      end)
    end
  end

  # ---

  # Уничтоженный вариант — в savepoint перед открытым: отказ открытого значит, что фикстуре нужны
  # события до неё, и сравнивать нечего.
  defp destroyed_failure(projection, dao, {path, event, _values}) do
    destroyed = rolled_back_savepoint(dao, fn -> project_or_error(projection, Personal.Test.destroyed(event)) end)
    open = rolled_back_savepoint(dao, fn -> project_or_error(projection, event) end)

    case {open, destroyed} do
      {:ok, {:error, reason}} -> [{path, reason}]
      {_open, _destroyed} -> []
    end
  end

  defp destroyed_result([]), do: :ok
  defp destroyed_result(failed), do: {:error, %{destroyed_failed: failed}}

  # ===== ПДн после уничтожения ключа =====

  @doc false
  @spec check_personal(module(), Path.t()) :: Result.unit(missing() | failed() | personal_left())

  def check_personal(projection, fixtures) when is_atom(projection) and is_binary(fixtures) do
    %{dao: dao, codec: codec, events: events} = declaration = projection.__es_projection__()
    destroys? = KeyDestroyed in events

    with {:ok, loaded} <- load_fixtures(declaration, fixtures) do
      rolled_back(dao, fn ->
        loaded
        |> personal_fixtures(codec)
        |> Enum.map(&personal_outcome(projection, dao, destroys?, &1))
        |> personal_result()
      end)
    end
  end

  # ---

  # Фикстура, на которой отказал сам `project/1`, требует событий до неё: искать после неё нечего.
  defp personal_outcome(projection, dao, destroys?, {path, event, values}) do
    rolled_back_savepoint(dao, fn ->
      before = table_writes(dao)

      case project_or_error(projection, event) do
        :ok -> {path, after_projected(projection, dao, destroys?, before, event, values)}
        {:error, _reason} -> {path, []}
      end
    end)
  end

  defp after_projected(projection, dao, destroys?, before, event, values) do
    case destroy_subjects(projection, destroys?, event, values) do
      :ok -> left(dao, written(before, table_writes(dao)), values)
      {:error, reason} -> {:key_destroyed_failed, reason}
    end
  end

  # Событие уничтожения ключа — на каждого субъекта ПДн-полей фикстуры. Актор события проекции не
  # нужен: он случайный.
  defp destroy_subjects(_projection, false, _event, _values), do: :ok

  defp destroy_subjects(projection, true, event, values) do
    by = ActorID.new!(Ecto.UUID.generate())

    values
    |> Enum.map(fn {_field, %Marker{subject: subject}} -> subject end)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn subject, :ok ->
      key_destroyed = Personal.Test.key_destroyed(SubjectID.new!(subject), by: by, at: event.at)

      case project_or_error(projection, key_destroyed) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp left(dao, tables, values) do
    for {schema, table} <- tables,
        row <- table_rows(dao, schema, table),
        {column, stored} <- Enum.sort(row),
        {field, %Marker{value: open}} <- values,
        string <- strings(open),
        contains?(stored, string),
        uniq: true,
        do: {"#{schema}.#{table}", column, field}
  end

  # Имена схемы и таблицы — из `pg_stat_xact_user_tables`, внешний ввод сюда не попадает, а
  # идентификатор в SQL не параметризуется.
  # sobelow_skip ["SQL.Query"]
  defp table_rows(dao, schema, table) do
    sql = "SELECT to_jsonb(t) FROM #{identifier(schema)}.#{identifier(table)} AS t"
    %{rows: rows} = Ecto.Adapters.SQL.query!(dao, sql, [])
    Enum.map(rows, fn [row] -> row end)
  end

  defp identifier(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")

  defp strings(value) when is_binary(value) and value != "", do: [value]
  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)
  defp strings(%{} = value), do: Enum.flat_map(Map.values(value), &strings/1)
  defp strings(_value), do: []

  defp contains?(stored, string) when is_binary(stored), do: String.contains?(stored, string)
  defp contains?(stored, string) when is_list(stored), do: Enum.any?(stored, &contains?(&1, string))
  defp contains?(%{} = stored, string), do: Enum.any?(Map.values(stored), &contains?(&1, string))
  defp contains?(_stored, _string), do: false

  defp personal_result(outcomes) do
    failed = for {path, {:key_destroyed_failed, reason}} <- outcomes, do: {path, reason}
    left = for {path, [_ | _] = left} <- outcomes, do: {path, left}

    case {failed, left} do
      {[], []} -> :ok
      {[], left} -> {:error, %{personal_left: left}}
      {failed, _left} -> {:error, %{key_destroyed_failed: failed}}
    end
  end

  # ===== общее =====

  # ПДн-значения фикстуры — маркеры дампа фасадом в полях нагрузки с `subject:`: субъект и открытое
  # wire-значение. Фикстура без таких полей в проверки ПДн не идёт.
  defp personal_fixtures(loaded, codec) do
    for {path, %mod{} = event} <- loaded,
        wires = subject_wires(mod.__es_payload__()),
        wires != [],
        do: {path, event, markers(codec.dump(event), wires)}
  end

  defp subject_wires(nil), do: []

  defp subject_wires(payload) do
    if Helper.Module.exports?(payload, :__es_payload_fields__, 0),
      do:
        for(
          %Core.Codec.Field{name: name, wire: wire, subject: subject} <- payload.__es_payload_fields__(),
          subject,
          do: {name, wire}
        ),
      else: []
  end

  defp markers(%{"payload" => %{} = payload}, wires),
    do: for({name, wire} <- wires, %Marker{} = marker <- [Map.get(payload, wire)], do: {name, marker})

  defp project_or_error(projection, event) do
    projection.project(event)
  rescue
    exception -> {:error, exception}
  end

  defp table_writes(dao) do
    %{rows: rows} = Ecto.Adapters.SQL.query!(dao, @table_writes_sql, [])
    Map.new(rows, fn [schema, table, count] -> {{schema, table}, count} end)
  end

  defp written(before, current) do
    for {table, count} <- Enum.sort(current), count > Map.get(before, table, 0), do: table
  end

  defp rolled_back_savepoint(dao, fun) do
    {:error, {:rolled_back, result}} = Savepoint.run(dao, fn -> {:error, {:rolled_back, fun.()}} end)
    result
  end

  # Проверка идёт в транзакции с откатом: savepoint'у нужна явная транзакция — в sandbox вне неё
  # каждый запрос идёт в своём savepoint Postgrex и снимает вложенные, — а строки read-модели
  # после проверки не остаются.
  defp rolled_back(dao, fun) do
    {:error, {:rolled_back, result}} = Transact.run(dao, fn -> {:error, {:rolled_back, fun.()}} end)
    result
  end

  defp load_fixtures(declaration, fixtures) do
    sources = sources(declaration, fixtures)

    with :ok <- check_present(sources) do
      sources
      |> Enum.map(&load_source(&1, declaration.codec))
      |> Enum.split_with(&match?({:ok, _loaded}, &1))
      |> case do
        {loaded, []} -> {:ok, Enum.map(loaded, &elem(&1, 1))}
        {_loaded, failed} -> {:error, %{failed: Enum.map(failed, &elem(&1, 1))}}
      end
    end
  end

  # Фикстура модуля — под типом агрегата и текущим тегом его кодека: у модуля из `events:` кодек
  # ровно один, его нашла проекция на компиляции.
  defp sources(%{events: events, streams: streams}, fixtures) do
    for mod <- events, mod != KeyDestroyed do
      {type, %{codec: event_codec}} =
        Enum.find(streams, fn {_type, %{codec: codec}} -> mod in codec.__es_mods__() end)

      tag = event_codec.type(mod)
      {Path.join([fixtures, type, tag <> ".json"]), mod, tag, event_codec}
    end
  end

  defp check_present(sources) do
    sources
    |> Enum.reject(fn {path, _mod, _tag, _event_codec} -> File.regular?(path) end)
    |> Enum.map(fn {path, mod, _tag, _event_codec} -> {path, mod} end)
    |> case do
      [] -> :ok
      missing -> {:error, %{missing: missing}}
    end
  end

  defp load_source({path, _mod, tag, event_codec}, codec) do
    case load_fixture(path, tag, event_codec, codec) do
      {:ok, event} -> {:ok, {path, event}}
      {:error, reason} -> {:error, {path, reason}}
    end
  end

  # Тег конверта — текущий тег модуля: фикстура источника `upcasts:` под его именем грузилась бы
  # апкастом, а её место — `Core.Es.EventCompatCase`.
  defp load_fixture(path, tag, event_codec, codec) do
    with {:ok, body} <- File.read(path),
         {:ok, data} <- Jason.decode(body),
         :ok <- check_type(data, tag) do
      event_codec.load(event_codec.__es_family__(), data, codec)
    end
  end

  defp check_type(%{"type" => type}, tag) when type != tag, do: {:error, %{type: type}}
  defp check_type(_data, _tag), do: :ok
end
