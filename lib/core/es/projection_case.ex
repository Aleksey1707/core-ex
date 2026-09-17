defmodule Core.Es.ProjectionCase do
  @moduledoc """
  Case-модуль проекции: очистка `clear/0` на golden-фикстурах событий.

      defmodule MyApp.Domain.<BC>.<Actor>.AccountList.ProjectionCaseTest do
        use Core.Es.ProjectionCase,
          projection: MyApp.Domain.<BC>.<Actor>.AccountList.Projection,
          async: false
      end

  Один тест-модуль на проекцию поверх `ExUnit.Case, async: false` со своим sandbox checkout на
  `repo:` проекции (по умолчанию `Core.Config.dao/0`): `TRUNCATE` в `clear/0` держит
  `ACCESS EXCLUSIVE` до конца sandbox-транзакции.

  Фикстура модуля из `events:` — `<тип агрегата>/<текущий тег>.json` от корня `fixtures:`; тип
  агрегата и тег берутся из кодека события, фикстура грузится фасадом `codec:` проекции. Тег в
  `type` фикстуры сверяется с текущим: фикстуры источников `upcasts:` не прогоняются, апкаст
  проверяет `Core.Es.EventCompatCase`. Нет фикстуры, в ней чужой тег или она не грузится — провал
  теста с путями.

  ## Генерируемый тест

  `clear/0` очищает каждую таблицу, которую пишет `project/1`: `project/1` на всех фикстурах,
  каждая в savepoint (отказ откатывается), затем `clear/0` и `count(*) = 0` у каждой таблицы, в
  которой `n_tup_ins + n_tup_upd + n_tup_del` из `pg_stat_xact_user_tables` вырос за прогон.
  Перечня таблиц нет: внутри открытой транзакции статистика не сбрасывается и считает попытки
  откаченных savepoint'ов, разница точна. Ни одной таблицы — провал. Таблица, в которой
  `project/1` на фикстурах не изменил ни строки (`UPDATE` строки, которой нет, `INSERT`,
  отвергнутый ограничением), в набор не попадает.

  Полноту `project/1` проверяет сборка проекции (`Core.Es.Projection`, «Полнота `project/1`»).

  Логика теста — функция `check_clear/2` (`:ok | {:error, detail}`) в транзакции с откатом, сам
  тест — `assert :ok = …`.

  ## Opts

  - `projection:` — модуль `use Core.Es.Projection`
  - `fixtures:` — корень фикстур от корня проекта, необязательная; по умолчанию
    `test/support/fixtures/events`
  - `async:` — только `false`, необязательная; явное значение требует
    `Credo.Check.Refactor.PassAsyncInTestCases`
  """

  alias Core.Helper
  alias Core.Helper.Savepoint
  alias Core.Helper.Transact

  @label "Es.ProjectionCase"
  @required_keys ~w(projection)a
  @optional_keys ~w(async fixtures)a
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
  фасада.
  """
  @type reason :: File.posix() | Jason.DecodeError.t() | %{type: term()} | Core.Error.t()

  @typedoc """
  Отказ `clear/0`, пустой набор таблиц или таблицы (`схема.имя`) со строками после `clear/0`.
  """
  @type uncleared ::
          %{clear: Core.Error.t()}
          | %{tables: []}
          | %{not_cleared: [{String.t(), pos_integer()}]}

  # ===== объявление =====

  @doc "Сгенерировать тест очистки `clear/0` проекции."
  defmacro __using__(opts) do
    lit = Macro.expand_literals(opts, __CALLER__)
    Helper.Opts.validate!(lit, @required_keys, @optional_keys, @label)
    projection = Helper.Opts.module!(lit, :projection, @label, exports: [__es_projection__: 0])
    fixtures = fixtures!(lit)
    :ok = ensure_sync!(lit)

    quote do
      use ExUnit.Case, async: false

      setup do
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(unquote(projection).__es_projection__().dao)
      end

      test "clear/0 очищает каждую таблицу, которую пишет project/1" do
        assert :ok = Core.Es.ProjectionCase.check_clear(unquote(projection), unquote(fixtures))
      end
    end
  end

  # ---

  defp fixtures!(opts) do
    case Keyword.get(opts, :fixtures, @fixtures_root) do
      fixtures when is_binary(fixtures) and fixtures != "" ->
        fixtures

      other ->
        raise CompileError,
          description:
            "#{@label}: fixtures: ожидается непустая строка — корень фикстур, получено " <>
              inspect(other)
    end
  end

  defp ensure_sync!(opts) do
    case Keyword.get(opts, :async, false) do
      false ->
        :ok

      other ->
        raise CompileError,
          description:
            "#{@label}: async: допускается только false — TRUNCATE в clear/0 держит блокировку " <>
              "до конца sandbox, получено #{inspect(other)}"
    end
  end

  # ===== полнота clear =====

  @doc false
  @spec check_clear(module(), Path.t()) :: :ok | {:error, missing() | failed() | uncleared()}

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
    for mod <- events do
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
      codec.load(event_codec.__codec_union__(), data)
    end
  end

  defp check_type(%{"type" => type}, tag) when type != tag, do: {:error, %{type: type}}
  defp check_type(_data, _tag), do: :ok
end
