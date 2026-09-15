defmodule Core.Es.EventCompatCase do
  @moduledoc """
  Case-модуль совместимости событий: golden-фикстуры агрегата против текущего кода его кодека.

      defmodule MyApp.Domain.<BC>.Common.Account.EventCompatTest do
        use Core.Es.EventCompatCase,
          aggregate: MyApp.Domain.<BC>.Common.Account,
          async: true
      end

      defmodule MyApp.Domain.<BC>.Common.Delivery.EventCompatTest do
        use Core.Es.EventCompatCase,
          event_codec: MyApp.Domain.<BC>.Common.Delivery.Event.Codec,
          async: true
      end

  Один тест-модуль на агрегат поверх `ExUnit.Case`. Семейство событий, тип агрегата и карта
  `upcasts:` берутся из кодека; фикстуры грузятся фасадом `Core.Config.codec/0` — так же, как
  события читает приложение, с апкастом.

  ## Генерируемые тесты

  1. у каждого тега `types/0` есть фикстура `<тег>.json`;
  2. каждая фикстура каталога, кроме источников `upcasts:`, несёт в `type` тег из имени файла и
     грузится через `codec.load(<Aggregate>.Event, _)`; посторонний `*.json` и фикстура тега,
     которого в кодеке нет, — провал;
  3. у каждого источника `upcasts:` есть фикстура;
  4. фикстура источника несёт его тег и грузится — апкастом, в модуль конца цепочки;
  5. при `aggregate:` — у `evolve/2` есть клауза события каждого тега: вызов
     `evolve(%Agg{id: aggregate_id}, событие)` на фикстуре тега. Провал — только
     `FunctionClauseError` самой `Agg.evolve/2`: тело клаузы вправе упасть на пустом состоянии,
     пропуском клаузы это не считается. Фикстуру без файла или незагружаемую ловят тесты 1 и 2.

  Логика теста — функция `check_*` (`:ok | {:error, detail}`), сам тест — `assert :ok = …`:
  провал печатает пути фикстур и причины.

  ## Opts

  - `aggregate:` — event-sourced агрегат (`use Core.Es.Aggregate`); кодек — его
    `__es_event_codec__/0`
  - `event_codec:` — кодек событий state-stored агрегата (`use Core.Es.Event.Codec`). Ровно одна
    из `aggregate:` и `event_codec:`, иначе `CompileError`
  - `fixtures:` — каталог фикстур от корня проекта, необязательная; по умолчанию
    `test/support/fixtures/events/<тип агрегата>`
  - `async:` — опция `ExUnit.Case`, необязательная, по умолчанию `true`; явное значение требует
    `Credo.Check.Refactor.PassAsyncInTestCases`
  """

  alias Core.Helper

  @label "Es.EventCompatCase"
  @required_keys []
  @optional_keys ~w(aggregate async event_codec fixtures)a
  @source_keys ~w(aggregate event_codec)a
  @codec_exports [__es_type__: 0, __es_upcasts__: 0]
  @fixtures_root "test/support/fixtures/events"

  @typedoc "Фикстуры, которых нет в каталоге."
  @type missing :: %{missing: [Path.t()]}

  @typedoc "Фикстуры, которые не загрузились, с причиной."
  @type failed :: %{failed: [{Path.t(), reason()}]}

  @typedoc "Фикстуры событий, для которых у `evolve/2` агрегата нет клаузы, с модулем события."
  @type unhandled :: %{unhandled: [{Path.t(), module()}]}

  @typedoc """
  Причина: файл не читается, не JSON, тег в конверте (`type`) не совпал с именем файла или
  ошибка фасада.
  """
  @type reason :: File.posix() | Jason.DecodeError.t() | %{type: term()} | Core.Error.t()

  @doc "Сгенерировать тесты golden-фикстур событий агрегата."
  defmacro __using__(opts) do
    lit = Macro.expand_literals(opts, __CALLER__)
    Helper.Opts.validate!(lit, @required_keys, @optional_keys, @label)
    {aggregate, event_codec} = source!(lit)
    fixtures = fixtures!(lit, event_codec)
    async = async!(lit)

    quote do
      use ExUnit.Case, async: unquote(async)

      test "у каждого тега есть фикстура" do
        assert :ok =
                 Core.Es.EventCompatCase.check_tag_fixtures(
                   unquote(event_codec),
                   unquote(fixtures)
                 )
      end

      test "каждая фикстура грузится под тегом из имени файла" do
        assert :ok =
                 Core.Es.EventCompatCase.check_fixtures_load(
                   unquote(event_codec),
                   unquote(fixtures),
                   Core.Config.codec()
                 )
      end

      test "у каждого источника upcasts: есть фикстура" do
        assert :ok =
                 Core.Es.EventCompatCase.check_upcast_fixtures(
                   unquote(event_codec),
                   unquote(fixtures)
                 )
      end

      test "фикстура источника upcasts: грузится апкастом" do
        assert :ok =
                 Core.Es.EventCompatCase.check_upcasts_load(
                   unquote(event_codec),
                   unquote(fixtures),
                   Core.Config.codec()
                 )
      end

      unquote(evolve_test(aggregate, fixtures))
    end
  end

  # ---

  defp source!(opts) do
    case Enum.filter(@source_keys, &Keyword.has_key?(opts, &1)) do
      [:event_codec] ->
        {nil, Helper.Opts.module!(opts, :event_codec, @label, exports: @codec_exports)}

      [:aggregate] ->
        aggregate =
          Helper.Opts.module!(opts, :aggregate, @label, exports: [__es_event_codec__: 0])

        event_codec =
          Helper.Opts.module!(
            [event_codec: aggregate.__es_event_codec__()],
            :event_codec,
            "#{@label}: #{inspect(aggregate)}",
            exports: @codec_exports
          )

        {aggregate, event_codec}

      keys ->
        raise CompileError,
          description:
            "#{@label}: ожидается ровно одна из опций aggregate: и event_codec:, получено " <>
              inspect(keys)
    end
  end

  defp fixtures!(opts, event_codec) do
    case Keyword.fetch(opts, :fixtures) do
      {:ok, fixtures} when is_binary(fixtures) and fixtures != "" ->
        fixtures

      {:ok, other} ->
        raise CompileError,
          description:
            "#{@label}: fixtures: ожидается непустая строка — каталог фикстур, получено " <>
              inspect(other)

      :error ->
        Path.join(@fixtures_root, event_codec.__es_type__())
    end
  end

  defp async!(opts) do
    case Keyword.get(opts, :async, true) do
      async when is_boolean(async) ->
        async

      other ->
        raise CompileError,
          description: "#{@label}: async: ожидается boolean, получено #{inspect(other)}"
    end
  end

  defp evolve_test(nil, _fixtures), do: nil

  defp evolve_test(aggregate, fixtures) do
    quote do
      test "у evolve/2 есть клауза события каждого тега" do
        assert :ok =
                 Core.Es.EventCompatCase.check_evolve(
                   unquote(aggregate),
                   unquote(fixtures),
                   Core.Config.codec()
                 )
      end
    end
  end

  @doc false
  @spec check_tag_fixtures(module(), Path.t()) :: :ok | {:error, missing()}

  def check_tag_fixtures(event_codec, fixtures)
      when is_atom(event_codec) and is_binary(fixtures) do
    event_codec.types()
    |> Enum.sort()
    |> check_present(fixtures)
  end

  @doc false
  @spec check_upcast_fixtures(module(), Path.t()) :: :ok | {:error, missing()}

  def check_upcast_fixtures(event_codec, fixtures)
      when is_atom(event_codec) and is_binary(fixtures) do
    check_present(upcast_sources(event_codec), fixtures)
  end

  # ---

  defp check_present(tags, fixtures) do
    tags
    |> Enum.map(&fixture_path(fixtures, &1))
    |> Enum.reject(&File.regular?/1)
    |> case do
      [] -> :ok
      paths -> {:error, %{missing: paths}}
    end
  end

  @doc false
  @spec check_fixtures_load(module(), Path.t(), module()) :: :ok | {:error, failed()}

  def check_fixtures_load(event_codec, fixtures, codec)
      when is_atom(event_codec) and is_binary(fixtures) and is_atom(codec) do
    upcasts = event_codec.__es_upcasts__()

    fixtures
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reject(&is_map_key(upcasts, tag(&1)))
    |> check_loaded(event_codec, codec)
  end

  @doc false
  @spec check_upcasts_load(module(), Path.t(), module()) :: :ok | {:error, failed()}

  def check_upcasts_load(event_codec, fixtures, codec)
      when is_atom(event_codec) and is_binary(fixtures) and is_atom(codec) do
    event_codec
    |> upcast_sources()
    |> Enum.map(&fixture_path(fixtures, &1))
    |> Enum.filter(&File.regular?/1)
    |> check_loaded(event_codec, codec)
  end

  # ---

  defp check_loaded(paths, event_codec, codec) do
    paths
    |> Enum.flat_map(&load_failure(&1, event_codec, codec))
    |> case do
      [] -> :ok
      failed -> {:error, %{failed: failed}}
    end
  end

  defp load_failure(path, event_codec, codec) do
    case load_fixture(path, event_codec, codec) do
      {:ok, _event} -> []
      {:error, reason} -> [{path, reason}]
    end
  end

  @doc false
  @spec check_evolve(module(), Path.t(), module()) :: :ok | {:error, unhandled()}

  def check_evolve(aggregate, fixtures, codec)
      when is_atom(aggregate) and is_binary(fixtures) and is_atom(codec) do
    event_codec = aggregate.__es_event_codec__()

    event_codec.types()
    |> Enum.sort()
    |> Enum.map(&fixture_path(fixtures, &1))
    |> Enum.flat_map(&unhandled(&1, aggregate, event_codec, codec))
    |> case do
      [] -> :ok
      unhandled -> {:error, %{unhandled: unhandled}}
    end
  end

  # ---

  defp unhandled(path, aggregate, event_codec, codec) do
    case load_fixture(path, event_codec, codec) do
      {:ok, %mod{} = event} ->
        if evolve_clause?(aggregate, event), do: [], else: [{path, mod}]

      {:error, _reason} ->
        []
    end
  end

  # Пропуск клаузы — только `FunctionClauseError` самой `evolve/2`: исключение из тела клаузы
  # или из функции, которую она зовёт, говорит о пустом состоянии, а не о пропущенном событии.
  defp evolve_clause?(aggregate, event) do
    evolves?(aggregate, event)
  rescue
    error in FunctionClauseError ->
      {error.module, error.function, error.arity} != {aggregate, :evolve, 2}

    _other ->
      true
  end

  defp evolves?(aggregate, event) do
    _state = aggregate.evolve(struct(aggregate, id: event.aggregate_id), event)
    true
  end

  defp load_fixture(path, event_codec, codec) do
    with {:ok, body} <- File.read(path),
         {:ok, data} <- Jason.decode(body),
         :ok <- check_type(data, tag(path)) do
      codec.load(event_codec.__codec_union__(), data)
    end
  end

  # Модуль выбирает тег конверта, а не имя файла: фикстура источника, перезаписанная текущим
  # дампом, иначе грузилась бы без апкаста. Конверт без тега отвергает сам кодек.
  defp check_type(%{"type" => type}, tag) when type != tag, do: {:error, %{type: type}}
  defp check_type(_data, _tag), do: :ok

  defp upcast_sources(event_codec) do
    event_codec.__es_upcasts__()
    |> Map.keys()
    |> Enum.sort()
  end

  defp tag(path), do: Path.basename(path, ".json")

  defp fixture_path(fixtures, tag), do: Path.join(fixtures, tag <> ".json")
end
