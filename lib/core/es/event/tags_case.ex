defmodule Core.Es.Event.TagsCase do
  @moduledoc """
  Case-модуль wire-тегов событий: тег квалифицирован типом агрегата и уникален на приложение.

      defmodule MyApp.Es.EventTagsTest do
        use Core.Es.Event.TagsCase,
          otp_app: :my_app,
          async: true
      end

  Один тест-модуль на приложение поверх `ExUnit.Case`. Область уникальности тега у кодека — он сам
  (`Core.Es.Event.Codec`), а в брокере, в хранилище событий и в странице потока тег лежит рядом
  с чужими: столкновение тегов двух агрегатов кодек не видит вовсе. Поэтому норма
  `app/14-events-outbox.md`, «Wire-тег события» держится тестом на всё дерево, а не сборкой кодека:
  сборка видит один кодек и проверила бы лишь локальную тень нормы.

  Кодеки — модули `otp_app:` (`Application.spec/2`) с `__es_type__/0`: его генерирует каждый
  `use Core.Es.Event.Codec`. Перечня нет: новый кодек попадает под проверку сам.

  Теги кодека — значения `tags:` **плюс ключи `upcasts:`**: ключ `upcasts:` — записанный тег,
  которого в `tags:` уже нет, и в хранилище он соседствует с чужими наравне. Значения `upcasts:`
  отдельно не проверяются: сборка кодека требует, чтобы цель была в `tags:` либо сама была
  источником, то есть цепочка сходится к `tags:`.

  ## Генерируемые тесты

  1. `type:` кодека записан в snake_case (`^[a-z][a-z0-9_]*$`): точка в нём сделала бы разбор
     `тип.тег` неоднозначным, а `type:` — первая часть адреса потока и имя каталога
     golden-фикстур, то есть сменить его так же нельзя, как тег;
  2. каждый тег кодека — `type:` плюс один и более сегментов `.<snake_case>`; кодек,
     провалившийся в тесте 1, этот тест пропускает: префикс считается от `type:`, и один дефект
     иначе даёт двойной отчёт;
  3. тег уникален между всеми кодеками приложения;
  4. `type:` уникален между всеми кодеками приложения: `Core.Codec.Facade` держит уникальность
     только среди плагинов одного фасада, а фасадов у приложения несколько.

  Уникальность (тесты 3 и 4) проверяется прямо, а не выводится из «префикс плюс уникальный
  `type:`»: вывод верен, только пока целы обе проверки.

  ## Записанные теги без префикса

  Записанный тег переименовать нельзя (ADR-0010, «Теги навсегда»), поэтому исключения адресные:
  `except_tags:` снимает проверку 2 с названных тегов названного кодека, `except_types:` —
  проверку 1 с названного кодека. Плоский список тегов на всё приложение не предлагается: он
  снял бы проверку с одноимённого тега в другом кодеке молча. Уникальность исключениями не
  снимается: она не зависит от того, когда тег записан.

  Список исключений MUST быть заморожен и пополняться только вместе со строкой `DEBT.md`
  приложения с причиной «строки с этим тегом записаны» (`app/19-testing.md`, «Ратчеты»).

  Логика теста — функция `check_*` (`:ok | {:error, detail}`), сам тест — `assert :ok = …`:
  провал печатает кодек и расхождение.

  ## Opts

  - `otp_app:` — приложение либо непустой список приложений, чьи кодеки проверяются; не загружено
    или ни одного кодека — провал всех тестов модуля. Список нужен зонтичному потребителю:
    `es_events` одна на базу, и проверка по одному приложению молчала бы о столкновении между ними
  - `except_tags:` — `%{Кодек => ["записанный тег"]}`, необязательная
  - `except_types:` — `[Кодек]`, необязательная
  - `async:` — опция `ExUnit.Case`, необязательная, по умолчанию `true`; явное значение требует
    `Credo.Check.Refactor.PassAsyncInTestCases`

  Макрос занимает в тест-модуле имена `@es_except_tags` и `@es_except_types`.
  """

  alias Core.Helper

  @label "Es.Event.TagsCase"
  @required_keys ~w(otp_app)a
  @optional_keys ~w(async except_tags except_types)a
  @type_format ~r/^[a-z][a-z0-9_]*$/
  @segment "[a-z][a-z0-9_]*"

  @typedoc "Кодек событий и его wire-имена: тип агрегата и теги (`tags:` плюс ключи `upcasts:`)."
  @type codec :: %{codec: module(), type: String.t(), tags: [String.t()]}

  @typedoc "Кодеки, чей `type:` записан не в snake_case."
  @type bad_type :: %{bad_type: [{module(), String.t()}]}

  @typedoc "Теги, не квалифицированные `type:` своего кодека."
  @type bad_tag :: %{bad_tag: [{module(), String.t()}]}

  @typedoc "Теги, объявленные более чем одним кодеком."
  @type duplicate_tags :: %{duplicate_tags: [{String.t(), [module()]}]}

  @typedoc "Типы агрегата, объявленные более чем одним кодеком."
  @type duplicate_types :: %{duplicate_types: [{String.t(), [module()]}]}

  # ===== объявление =====

  @doc "Сгенерировать тесты wire-тегов событий приложения."
  defmacro __using__(opts) do
    lit = Macro.expand_literals(opts, __CALLER__)
    Helper.Opts.validate!(lit, @required_keys, @optional_keys, @label)
    otp_apps = otp_apps!(lit)
    async = async!(lit)

    # `except_tags:` и `except_types:` уходят в тело тест-модуля как есть: map на этапе
    # разворачивания макроса ещё AST, а значение атрибута оттуда не прочитать.
    except_tags = Keyword.get(opts, :except_tags, quote(do: %{}))
    except_types = Keyword.get(opts, :except_types, quote(do: []))

    quote do
      use ExUnit.Case, async: unquote(async)

      @es_except_tags Core.Es.Event.TagsCase.except_tags!(unquote(except_tags))
      @es_except_types Core.Es.Event.TagsCase.except_types!(unquote(except_types))

      setup_all do
        %{codecs: Core.Es.Event.TagsCase.codecs!(unquote(otp_apps))}
      end

      test "type: агрегата записан в snake_case", %{codecs: codecs} do
        assert :ok = Core.Es.Event.TagsCase.check_type_format(codecs, @es_except_types)
      end

      test "каждый тег квалифицирован type: агрегата", %{codecs: codecs} do
        assert :ok = Core.Es.Event.TagsCase.check_tag_format(codecs, @es_except_tags, @es_except_types)
      end

      test "тег уникален между кодеками приложения", %{codecs: codecs} do
        assert :ok = Core.Es.Event.TagsCase.check_tag_uniqueness(codecs)
      end

      test "type: уникален между кодеками приложения", %{codecs: codecs} do
        assert :ok = Core.Es.Event.TagsCase.check_type_uniqueness(codecs)
      end
    end
  end

  # ---

  defp otp_apps!(opts) do
    case Keyword.fetch!(opts, :otp_app) do
      app when is_atom(app) and not is_nil(app) ->
        [app]

      [_ | _] = apps ->
        Enum.each(apps, &app!/1)
        apps

      other ->
        raise CompileError,
          description: "#{@label}: otp_app: ожидается атом или непустой список атомов, получено " <> inspect(other)
    end
  end

  defp app!(app) when is_atom(app) and not is_nil(app), do: :ok

  defp app!(other) do
    raise CompileError, description: "#{@label}: otp_app: ожидается атом, получено #{inspect(other)}"
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

  # ===== опции исключений =====

  @doc false
  @spec except_tags!(term()) :: %{optional(module()) => [String.t()]}

  def except_tags!(excepts) when is_map(excepts) do
    Enum.each(excepts, &except_tags_entry!/1)
    excepts
  end

  def except_tags!(other) do
    raise CompileError,
      description: ~s(#{@label}: except_tags: ожидается map %{Кодек => ["тег"]}, получено ) <> inspect(other)
  end

  @doc false
  @spec except_types!(term()) :: [module()]

  def except_types!(types) when is_list(types) do
    Enum.each(types, &codec!/1)
    types
  end

  def except_types!(other) do
    raise CompileError,
      description: "#{@label}: except_types: ожидается список кодеков, получено #{inspect(other)}"
  end

  # ---

  defp except_tags_entry!({codec, tags}) when is_atom(codec) and not is_nil(codec) and is_list(tags) do
    Enum.each(tags, &tag!(&1, codec))
  end

  defp except_tags_entry!({codec, tags}) do
    raise CompileError,
      description: ~s(#{@label}: except_tags: ожидается пара {Кодек, ["тег"]}, получено ) <> inspect({codec, tags})
  end

  defp tag!(tag, _codec) when is_binary(tag) and tag != "", do: :ok

  defp tag!(other, codec) do
    raise CompileError,
      description: "#{@label}: except_tags: у #{inspect(codec)} ожидается непустая строка, получено " <> inspect(other)
  end

  defp codec!(codec) when is_atom(codec) and not is_nil(codec), do: :ok

  defp codec!(other) do
    raise CompileError,
      description: "#{@label}: except_types: ожидается кодек, получено #{inspect(other)}"
  end

  # ===== кодеки приложения =====

  @doc false
  @spec codecs!(atom() | [atom()]) :: [codec(), ...]

  def codecs!(otp_app) when is_atom(otp_app), do: codecs!([otp_app])

  def codecs!(otp_apps) when is_list(otp_apps) do
    case Enum.flat_map(otp_apps, &app_codecs!/1) do
      [] -> raise ArgumentError, "#{@label}: в #{inspect(otp_apps)} нет кодеков событий"
      codecs -> Enum.sort_by(codecs, & &1.codec)
    end
  end

  # ---

  defp app_codecs!(otp_app) do
    case Application.spec(otp_app, :modules) do
      nil -> raise ArgumentError, "#{@label}: приложение #{inspect(otp_app)} не загружено"
      modules -> for module <- modules, codec?(module), do: describe(module)
    end
  end

  # `function_exported?/3` не грузит модуль: ещё не загруженный кодек иначе выпал бы из сверки молча.
  defp codec?(module), do: Code.ensure_loaded?(module) and function_exported?(module, :__es_type__, 0)

  defp describe(codec), do: %{codec: codec, type: codec.__es_type__(), tags: tags(codec)}

  defp tags(codec) do
    tags = MapSet.to_list(codec.types()) ++ Map.keys(codec.__es_upcasts__())
    Enum.sort(tags)
  end

  # ===== формат типа =====

  @doc false
  @spec check_type_format([codec()], [module()]) :: :ok | {:error, bad_type()}

  def check_type_format(codecs, except_types) when is_list(codecs) and is_list(except_types) do
    codecs
    |> Enum.reject(&(&1.codec in except_types or valid_type?(&1)))
    |> Enum.map(&{&1.codec, &1.type})
    |> result(:bad_type)
  end

  # ===== квалификация тега =====

  @doc false
  @spec check_tag_format([codec()], %{optional(module()) => [String.t()]}, [module()]) ::
          :ok | {:error, bad_tag()}

  def check_tag_format(codecs, except_tags, except_types)
      when is_list(codecs) and is_map(except_tags) and is_list(except_types) do
    codecs
    |> Enum.filter(&(valid_type?(&1) or &1.codec in except_types))
    |> Enum.flat_map(&unqualified(&1, Map.get(except_tags, &1.codec, [])))
    |> result(:bad_tag)
  end

  # ---

  defp unqualified(%{codec: codec, type: type, tags: tags}, except) do
    format = tag_format(type)

    for tag <- tags, tag not in except, not Regex.match?(format, tag), do: {codec, tag}
  end

  defp tag_format(type), do: Regex.compile!("^#{Regex.escape(type)}(\\.#{@segment})+$")

  # ===== уникальность =====

  @doc false
  @spec check_tag_uniqueness([codec()]) :: :ok | {:error, duplicate_tags()}

  def check_tag_uniqueness(codecs) when is_list(codecs) do
    codecs
    |> Enum.flat_map(fn %{codec: codec, tags: tags} -> Enum.map(tags, &{&1, codec}) end)
    |> duplicates()
    |> result(:duplicate_tags)
  end

  @doc false
  @spec check_type_uniqueness([codec()]) :: :ok | {:error, duplicate_types()}

  def check_type_uniqueness(codecs) when is_list(codecs) do
    codecs
    |> Enum.map(&{&1.type, &1.codec})
    |> duplicates()
    |> result(:duplicate_types)
  end

  # ---

  defp duplicates(pairs) do
    pairs
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_value, codecs} -> length(codecs) > 1 end)
    |> Enum.map(fn {value, codecs} -> {value, Enum.sort(codecs)} end)
  end

  # ===== общее =====

  defp valid_type?(%{type: type}), do: Regex.match?(@type_format, type)

  defp result([], _key), do: :ok
  defp result(found, key), do: {:error, %{key => Enum.sort(found)}}
end
