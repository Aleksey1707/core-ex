defmodule Core.Es.EventCompatCase do
  @moduledoc """
  Case-модуль совместимости событий: golden-фикстуры агрегата против текущего кода его кодека.

      defmodule MyApp.Domain.<BC>.Account.EventCompatTest do
        use Core.Es.EventCompatCase,
          aggregate: MyApp.Domain.<BC>.Account,
          async: true
      end

      defmodule MyApp.Domain.<BC>.Delivery.EventCompatTest do
        use Core.Es.EventCompatCase,
          event_codec: MyApp.Domain.<BC>.Delivery.Event.Codec,
          async: true
      end

  Один тест-модуль на агрегат поверх `ExUnit.Case`. Семейство событий, тип агрегата и карта
  `upcasts:` берутся из кодека; фикстуры грузятся фасадом `Core.Config.codec/0` — так же, как
  события читает приложение, с апкастом.

  ## Генерируемые тесты

  1. у каждого тега `types/0` есть фикстура `<тег>.json`;
  2. каждая фикстура каталога, кроме источников `upcasts:`, несёт в `type` тег из имени файла и
     грузится кодеком по семейству `<Aggregate>.Event` с фасадом `Core.Config.codec/0`; посторонний
     `*.json` и фикстура тега, которого в кодеке нет, — провал;
  3. у каждого источника `upcasts:` есть фикстура;
  4. фикстура источника несёт его тег и грузится — апкастом, в модуль конца цепочки;
  5. персональный Prim (`personal: true`) в загруженной фикстуре текущего тега лежит только в поле
     нагрузки верхнего уровня с `subject:`: вложенную сущность, `entity:`, `union:` и `type:`
     сборка нагрузки не проверяет. Видно только заполненное значение.

  Уничтоженный вариант `destroyed/<тег>.json` — фикстура с `{"$pd": null}` на месте каждого
  ПДн-значения (ADR-0078):

  - у текущего тега с полем `subject:` он есть;
  - он несёт тег из имени файла и грузится: у текущего тега — с `%Core.Es.Personal.Destroyed{}` в
    каждом поле с `subject:`, у источника `upcasts:` — апкастом, без требования уничтоженного
    значения в результате. Вариант текущего тега без `subject:` и тега вне кодека — провал.

  Фикстура — конверт после расшифровки: на месте ПДн-значения открытое wire-значение. Шифротекст
  `{"$pd": "<строка>"}` в ней — провал с кодом `:sealed_personal_value`. Тела обеих фикстур отдаёт
  `Core.Es.Personal.Test.fixtures/1`. Case не трогает ни БД, ни хранилище ключей.

  Полноту `evolve/2` event-sourced агрегата проверяет сборка его репозитория
  (`Core.Es.Aggregate.Repo`, «Полнота `evolve`»).

  Логика теста — функция `check_*` (`:ok | {:error, detail}`), сам тест — `assert :ok = …`:
  провал печатает пути фикстур и причины.

  ## Opts

  - `aggregate:` — event-sourced агрегат (`use Core.Es.Aggregate`), источник кодека — его
    `__es_event_codec__/0`
  - `event_codec:` — кодек событий state-stored агрегата (`use Core.Es.Event.Codec`). Ровно одна
    из `aggregate:` и `event_codec:`, иначе `CompileError`
  - `fixtures:` — каталог фикстур от корня проекта, необязательная; по умолчанию
    `test/support/fixtures/events/<тип агрегата>`
  - `async:` — опция `ExUnit.Case`, необязательная, по умолчанию `true`; явное значение требует
    `Credo.Check.Refactor.PassAsyncInTestCases`
  """

  alias Core.Es.Personal.Destroyed
  alias Core.Helper
  alias Core.Prim
  alias Core.Result

  @label "Es.EventCompatCase"
  @required_keys ~w()a
  @optional_keys ~w(aggregate async event_codec fixtures)a
  @expression_keys ~w()a
  @source_keys ~w(aggregate event_codec)a
  @codec_exports [__es_type__: 0, __es_upcasts__: 0, __es_subjects__: 0]
  @fixtures_root "test/support/fixtures/events"

  @typedoc "Фикстуры, которых нет в каталоге."
  @type missing :: %{missing: [Path.t()]}

  @typedoc "Фикстуры, которые не загрузились, с причиной."
  @type failed :: %{failed: [{Path.t(), reason()}]}

  @typedoc """
  Причина: файл не читается, не JSON, тег в конверте (`type`) не совпал с именем файла или
  ошибка фасада; у уничтоженного варианта текущего тега — у события нет полей с `subject:`
  (`subjects: []`) или в перечисленных полях не уничтоженное значение (`open:`).
  """
  @type reason ::
          File.posix()
          | Jason.DecodeError.t()
          | %{type: term()}
          | %{subjects: []}
          | %{open: [atom(), ...]}
          | Core.Error.t()

  @typedoc "Фикстуры с персональным Prim вне поля `subject:`: пути к значениям в событии."
  @type personal :: %{failed: [{Path.t(), %{personal: [[term()], ...]}}]}

  # ===== объявление =====

  @doc "Сгенерировать тесты golden-фикстур событий агрегата."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)
    event_codec = source!(opts)
    fixtures = fixtures!(opts, event_codec)
    async = async!(opts)

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

      test "персональный Prim — только в поле с subject:" do
        assert :ok =
                 Core.Es.EventCompatCase.check_personal_fields(
                   unquote(event_codec),
                   unquote(fixtures),
                   Core.Config.codec()
                 )
      end

      test "у текущего тега с subject: есть уничтоженный вариант" do
        assert :ok =
                 Core.Es.EventCompatCase.check_destroyed_fixtures(
                   unquote(event_codec),
                   unquote(fixtures)
                 )
      end

      test "уничтоженный вариант грузится под тегом из имени файла" do
        assert :ok =
                 Core.Es.EventCompatCase.check_destroyed_load(
                   unquote(event_codec),
                   unquote(fixtures),
                   Core.Config.codec()
                 )
      end
    end
  end

  # ---

  defp source!(opts) do
    case Enum.filter(@source_keys, &Keyword.has_key?(opts, &1)) do
      [:event_codec] ->
        Helper.Opts.module!(opts, :event_codec, @label, exports: @codec_exports)

      [:aggregate] ->
        aggregate =
          Helper.Opts.module!(opts, :aggregate, @label, exports: [__es_event_codec__: 0])

        Helper.Opts.module!(
          [event_codec: aggregate.__es_event_codec__()],
          :event_codec,
          "#{@label}: aggregate",
          exports: @codec_exports
        )

      keys ->
        Helper.Opts.reject!(
          @label,
          "ожидается ровно одна из опций aggregate: и event_codec:, получено #{inspect(keys)}"
        )
    end
  end

  defp fixtures!(opts, event_codec) do
    case Keyword.fetch(opts, :fixtures) do
      {:ok, fixtures} when is_binary(fixtures) and fixtures != "" ->
        fixtures

      {:ok, other} ->
        Helper.Opts.reject!(
          "#{@label}: fixtures",
          "ожидается непустая строка — каталог фикстур, получено #{inspect(other)}"
        )

      :error ->
        Path.join(@fixtures_root, event_codec.__es_type__())
    end
  end

  defp async!(opts) do
    case Keyword.get(opts, :async, true) do
      async when is_boolean(async) ->
        async

      other ->
        Helper.Opts.reject!("#{@label}: async", "ожидается boolean, получено #{inspect(other)}")
    end
  end

  # ===== наличие фикстур =====

  @doc false
  @spec check_tag_fixtures(module(), Path.t()) :: Result.unit(missing())

  def check_tag_fixtures(event_codec, fixtures)
      when is_atom(event_codec) and is_binary(fixtures) do
    event_codec.types()
    |> Enum.sort()
    |> check_present(fixtures)
  end

  @doc false
  @spec check_upcast_fixtures(module(), Path.t()) :: Result.unit(missing())

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

  # ===== загрузка фикстур =====

  @doc false
  @spec check_fixtures_load(module(), Path.t(), module()) :: Result.unit(failed())

  def check_fixtures_load(event_codec, fixtures, codec)
      when is_atom(event_codec) and is_binary(fixtures) and is_atom(codec) do
    event_codec
    |> current_fixtures(fixtures)
    |> collect_failures(&load_failure(&1, event_codec, codec))
  end

  @doc false
  @spec check_upcasts_load(module(), Path.t(), module()) :: Result.unit(failed())

  def check_upcasts_load(event_codec, fixtures, codec)
      when is_atom(event_codec) and is_binary(fixtures) and is_atom(codec) do
    event_codec
    |> upcast_sources()
    |> Enum.map(&fixture_path(fixtures, &1))
    |> Enum.filter(&File.regular?/1)
    |> collect_failures(&load_failure(&1, event_codec, codec))
  end

  # ---

  defp load_failure(path, event_codec, codec) do
    case load_fixture(path, event_codec, codec) do
      {:ok, _event} -> []
      {:error, reason} -> [{path, reason}]
    end
  end

  # ===== персональный Prim =====

  @doc false
  @spec check_personal_fields(module(), Path.t(), module()) :: Result.unit(personal())

  def check_personal_fields(event_codec, fixtures, codec)
      when is_atom(event_codec) and is_binary(fixtures) and is_atom(codec) do
    event_codec
    |> current_fixtures(fixtures)
    |> collect_failures(&personal_failure(&1, event_codec, codec))
  end

  # ---

  # Незагруженную фикстуру показывает `check_fixtures_load/3`: здесь она не дублируется.
  defp personal_failure(path, event_codec, codec) do
    with {:ok, event} <- load_fixture(path, event_codec, codec),
         [_ | _] = paths <- personal_paths(event, event_codec) do
      [{path, %{personal: paths}}]
    else
      _ -> []
    end
  end

  defp personal_paths(%mod{payload: payload} = event, event_codec) do
    hidden = Keyword.keys(subjects(event_codec, mod))
    payload = if is_map(payload), do: Map.drop(payload, hidden), else: payload

    event
    |> Map.from_struct()
    |> Map.put(:payload, payload)
    |> personal_values([])
    |> Enum.sort()
  end

  defp personal_values(%mod{} = value, path) do
    cond do
      not Prim.prim?(mod) -> personal_values(Map.from_struct(value), path)
      mod.__domain_personal__() -> [Enum.reverse(path)]
      true -> []
    end
  end

  defp personal_values(%{} = map, path),
    do: Enum.flat_map(map, fn {key, value} -> personal_values(value, [key | path]) end)

  defp personal_values(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> personal_values(value, [index | path]) end)
  end

  defp personal_values(_value, _path), do: []

  # ===== уничтоженный вариант =====

  @doc false
  @spec check_destroyed_fixtures(module(), Path.t()) :: Result.unit(missing())

  def check_destroyed_fixtures(event_codec, fixtures)
      when is_atom(event_codec) and is_binary(fixtures) do
    event_codec.__es_subjects__()
    |> Map.keys()
    |> Enum.map(&event_codec.type/1)
    |> Enum.sort()
    |> check_present(destroyed_dir(fixtures))
  end

  @doc false
  @spec check_destroyed_load(module(), Path.t(), module()) :: Result.unit(failed())

  def check_destroyed_load(event_codec, fixtures, codec)
      when is_atom(event_codec) and is_binary(fixtures) and is_atom(codec) do
    fixtures
    |> destroyed_dir()
    |> json_files()
    |> collect_failures(&destroyed_failure(&1, event_codec, codec))
  end

  # ---

  defp destroyed_failure(path, event_codec, codec) do
    with {:ok, event} <- load_fixture(path, event_codec, codec),
         :ok <- check_destroyed(event, tag(path), event_codec) do
      []
    else
      {:error, reason} -> [{path, reason}]
    end
  end

  # Апкаст MAY удалить или переложить поле: у источника уничтоженное значение в результате не
  # требуется (ADR-0078). Тег вне кодека отвергает загрузка — `:unknown_event_type`.
  defp check_destroyed(%mod{payload: payload}, tag, event_codec) do
    if is_map_key(event_codec.__es_upcasts__(), tag),
      do: :ok,
      else: check_all_destroyed(payload, Keyword.keys(subjects(event_codec, mod)))
  end

  defp check_all_destroyed(_payload, []), do: {:error, %{subjects: []}}

  defp check_all_destroyed(payload, fields) do
    case Enum.reject(fields, &match?(%Destroyed{}, Map.fetch!(payload, &1))) do
      [] -> :ok
      open -> {:error, %{open: open}}
    end
  end

  defp destroyed_dir(fixtures), do: Path.join(fixtures, "destroyed")

  # ===== общее =====

  defp collect_failures(paths, failure) do
    case Enum.flat_map(paths, failure) do
      [] -> :ok
      failed -> {:error, %{failed: failed}}
    end
  end

  defp current_fixtures(event_codec, fixtures) do
    upcasts = event_codec.__es_upcasts__()

    fixtures
    |> json_files()
    |> Enum.reject(&is_map_key(upcasts, tag(&1)))
  end

  defp json_files(dir) do
    dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp load_fixture(path, event_codec, codec) do
    with {:ok, body} <- File.read(path),
         {:ok, data} <- Jason.decode(body),
         :ok <- check_type(data, tag(path)) do
      event_codec.load(event_codec.__es_family__(), data, codec)
    end
  end

  # Модуль выбирает тег конверта, а не имя файла: фикстура источника, перезаписанная текущим
  # дампом, иначе грузилась бы без апкаста. Конверт без тега отвергает сам кодек.
  defp check_type(%{"type" => type}, tag) when type != tag, do: {:error, %{type: type}}
  defp check_type(_data, _tag), do: :ok

  defp tag(path), do: Path.basename(path, ".json")

  defp subjects(event_codec, mod), do: Map.get(event_codec.__es_subjects__(), mod, [])

  defp upcast_sources(event_codec) do
    event_codec.__es_upcasts__()
    |> Map.keys()
    |> Enum.sort()
  end

  defp fixture_path(fixtures, tag), do: Path.join(fixtures, tag <> ".json")
end
