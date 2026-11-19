defmodule Core.Labels.CompletenessCase do
  @moduledoc """
  Case-модуль полноты подписей: у каждого события приложения название и автор — учётная запись, у
  каждого struct'а, Enum и id, достижимых из нагрузки, — объявление (ADR-0063).

      defmodule MyApp.Labels.CompletenessTest do
        use Core.Labels.CompletenessCase,
          otp_app: :my_app,
          async: true
      end

  Один тест-модуль на приложение поверх `ExUnit.Case`. Сборка объявлений видит один модуль: событие
  без `use Core.Labels.Event` собирается, Enum без `use Core.Labels.Values` и id без
  `use Core.Labels.ID` — тоже, а сведения по ним ломаются только на странице событий. Поэтому
  полнота держится тестом на всё дерево, а не сборкой.

  Модули приложения перечисляет `:application.get_key/2`. Кодеки — модули, которые
  `Core.Es.Event.Codec.codec?/1` признаёт кодеком событий, семейства — плагины с `__codec_union__/0`
  (`use Core.Codec.Plugin, union:`). Перечня нет: новый кодек попадает под проверку сам, без новой
  строки теста. Обход идёт от событий кодеков по спеке нагрузки (`Core.Labels.Fields`): во вложенные
  struct'ы, списки, множества, ключи и значения словарей (`map:`) и варианты семейства. Вариант
  семейства объявляет себя по своему виду: Prim — как Prim (вид или текст значения), struct — как
  struct (решение по полям); скрытое поле-семейство не проверяется. Автор события
  (`by`) в сведения не выходит, но событие страницы событий с подписями (`Core.Web.Event`,
  `labels: true` требует `user_ref:`) дампит его ссылкой на учётную запись с именем из словаря ссылок,
  а словарь находит только id с резолвером — иначе `ArgumentError` на первом событии. Ключи и
  значения свободной map'ы (`type: :map`) спеки нет, и вид id в них ратчет не видит: его проверяет
  только построение сведений.

  ## Генерируемые тесты

  1. обход находит хотя бы одно событие: ратчет, который ничего не нашёл, не проходит. Числовых
     нижних границ нет — их пришлось бы двигать с каждым событием;
  2. у каждого события название (`Core.Labels.Event`);
  3. автор каждого события (`__es_by__/0`) — Prim с `use Core.Labels.ID, kind: :user` и `resolver:`;
     пробел — `{событие, :by, Prim автора}`;
  4. у каждого struct'а, достижимого из нагрузки, — нагрузки, вложенного struct'а, варианта
     семейства — решение по полям (`Core.Labels.Fields`); вариант-Prim проверяется как Prim (п. 6);
  5. у каждого Enum, достижимого из нагрузки, подписи значений (`Core.Labels.Values`);
  6. у каждого Prim-идентификатора, достижимого из нагрузки, — поля, значения словаря, варианта
     видимого семейства `union:` — вид (`Core.Labels.ID`) или текст (`Core.Labels.Text`): свой или
     базы композита. Prim со своим kind (`Core.Labels.Kind.of/1` — `{:custom, _}`) — пробел, как и
     id без вида: в сведениях вида у него нет;
  7. спека видимых полей каждого варианта семейства с подписями совпадает с его декларацией
     (`__core_fields__/0`): иначе подписи варианта разошлись бы с его wire-формой. Поле-дискриминатор
     в wire варианта не входит и не сверяется. Семейство поля `union:` без плагина среди модулей
     `otp_app:` — провал, даже если плагин лежит в другом приложении: его вариантов обход не знает.

  Логика теста — функция `check_*` (`:ok | {:error, пробелы}`), сам тест — `assert :ok = …`:
  провал перечисляет все пробелы разом, с модулем-владельцем, полем и модулем без объявления.

  ## Opts

  - `otp_app:` — приложение, чьи модули проверяются, обязательная; не загружено — провал всех тестов
  - `async:` — опция `ExUnit.Case`, необязательная, по умолчанию `true`; явное значение требует
    `Credo.Check.Refactor.PassAsyncInTestCases`
  """

  alias Core.Helper
  alias Core.Labels.Fields
  alias Core.Labels.ID
  alias Core.Labels.Kind
  alias Core.Labels.Walk
  alias Core.Result

  @label "Labels.CompletenessCase"
  @required_keys ~w(otp_app)a
  @optional_keys ~w(async)a
  @expression_keys ~w()a

  @typedoc "Пробел: модуль-владелец, поле и модуль значения без объявления."
  @type place :: {module(), atom(), module()}

  @typedoc "События без названия."
  @type untitled :: %{untitled: [module()]}

  @typedoc "Авторы событий, которых словарь ссылок не назовёт учётной записью: `{событие, :by, Prim автора}`."
  @type unnamed :: %{unnamed: [place()]}

  @typedoc "Struct'ы без решения по полям."
  @type undecided :: %{undecided: [place()]}

  @typedoc "Enum без подписей значений."
  @type unlabelled :: %{unlabelled: [place()]}

  @typedoc "Prim-идентификаторы без вида: `Kind.of/1` — `:unkinded` или `{:custom, _}`."
  @type unkinded :: %{unkinded: [place()]}

  @typedoc """
  Варианты, чья спека поля расходится со спекой `__core_fields__/0` (`{подписи, IR}`, `nil` — спеки
  нет; при одной декларации недостижимо), и семейства без плагина.
  """
  @type variants :: %{
          optional(:diverged) => [{module(), atom(), {Fields.spec() | nil, Fields.spec() | nil}}],
          optional(:unknown_family) => [place()]
        }

  # ===== объявление =====

  @doc "Сгенерировать тесты полноты подписей приложения."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)
    otp_app = Helper.Opts.atom!(opts, :otp_app, @label)
    async = async!(opts)

    quote do
      use ExUnit.Case, async: unquote(async)

      setup_all do
        %{modules: Core.Labels.CompletenessCase.modules!(unquote(otp_app))}
      end

      test "обход находит события", %{modules: modules} do
        assert :ok = Core.Labels.CompletenessCase.check_found(modules)
      end

      test "у каждого события название", %{modules: modules} do
        assert :ok = Core.Labels.CompletenessCase.check_titles(modules)
      end

      test "у автора каждого события вид учётной записи с резолвером", %{modules: modules} do
        assert :ok = Core.Labels.CompletenessCase.check_authors(modules)
      end

      test "у каждого struct'а нагрузки решение по полям", %{modules: modules} do
        assert :ok = Core.Labels.CompletenessCase.check_fields(modules)
      end

      test "у каждого Enum нагрузки подписи значений", %{modules: modules} do
        assert :ok = Core.Labels.CompletenessCase.check_values(modules)
      end

      test "у каждого id нагрузки вид", %{modules: modules} do
        assert :ok = Core.Labels.CompletenessCase.check_ids(modules)
      end

      test "спека варианта семейства совпадает со спекой плагина", %{modules: modules} do
        assert :ok = Core.Labels.CompletenessCase.check_variants(modules)
      end
    end
  end

  # ---

  defp async!(opts) do
    case Keyword.get(opts, :async, true) do
      async when is_boolean(async) ->
        async

      other ->
        Helper.Opts.reject!("#{@label}: async", "ожидается boolean, получено #{inspect(other)}")
    end
  end

  # ===== модули приложения =====

  @doc false
  @spec modules!(atom()) :: [module()]

  def modules!(app) when is_atom(app) do
    case :application.get_key(app, :modules) do
      {:ok, modules} -> modules
      :undefined -> raise ArgumentError, "#{@label}: приложение #{inspect(app)} не загружено"
    end
  end

  # ===== проверки =====

  @doc false
  @spec check_found([module()]) :: Result.unit(:empty)

  def check_found(modules) when is_list(modules) do
    case Walk.declarations(modules).events do
      [] -> {:error, :empty}
      [_ | _] -> :ok
    end
  end

  @doc false
  @spec check_titles([module()]) :: Result.unit(untitled())

  def check_titles(modules) when is_list(modules) do
    result(
      untitled:
        for(
          event <- Walk.declarations(modules).events,
          not Helper.Module.exports?(event, :__label_title__, 0),
          do: event
        )
    )
  end

  @doc false
  @spec check_authors([module()]) :: Result.unit(unnamed())

  def check_authors(modules) when is_list(modules) do
    unnamed =
      for event <- Walk.declarations(modules).events, by = event.__es_by__(), not user?(by), do: {event, :by, by}

    result(unnamed: unnamed)
  end

  @doc false
  @spec check_fields([module()]) :: Result.unit(undecided())

  def check_fields(modules) when is_list(modules) do
    undecided =
      for {:struct, owner, field, module} <- Walk.declarations(modules).places,
          not Fields.labelled?(module),
          do: {owner, field, module}

    result(undecided: undecided)
  end

  @doc false
  @spec check_values([module()]) :: Result.unit(unlabelled())

  def check_values(modules) when is_list(modules) do
    unlabelled =
      for {:enum, owner, field, module} <- Walk.declarations(modules).places,
          not Helper.Module.exports?(module, :labels, 0),
          do: {owner, field, module}

    result(unlabelled: unlabelled)
  end

  @doc false
  @spec check_ids([module()]) :: Result.unit(unkinded())

  def check_ids(modules) when is_list(modules) do
    unkinded =
      for {:prim, owner, field, module} <- Walk.declarations(modules).places,
          unkinded?(module),
          do: {owner, field, module}

    result(unkinded: unkinded)
  end

  @doc false
  @spec check_variants([module()]) :: Result.unit(variants())

  def check_variants(modules) when is_list(modules) do
    unknown = for {:family, owner, field, family} <- Walk.declarations(modules).places, do: {owner, field, family}

    diverged =
      for plugin <- modules,
          family = union(plugin),
          variant <- Core.Union.variants(family),
          variant.kind == :domain,
          Fields.labelled?(variant.module),
          gap <- diverged(variant.module, disc(variant.address), variant_fields(variant.module)),
          do: gap

    result(diverged: diverged, unknown_family: unknown)
  end

  # ---

  defp user?(module), do: match?(%{kind: :user}, ID.find(module))

  defp unkinded?(module) do
    case Kind.of(module) do
      {:unkinded, _leaf} -> true
      {:custom, _leaf} -> true
      _declared -> false
    end
  end

  defp union(plugin) do
    if Helper.Module.exports?(plugin, :__codec_union__, 0), do: plugin.__codec_union__()
  end

  defp variant_fields(variant) do
    for field <- Core.Field.introspect(variant) || [],
        do: {field.name, Core.Field.wire_spec(field.spec)}
  end

  defp diverged(variant, disc, fields) do
    plugin = Map.new(fields)
    labelled = Map.new(Fields.specs(variant))
    hidden = for {name, :hidden} <- Fields.labels(variant), do: name

    for name <- Enum.uniq(Map.keys(plugin) ++ Map.keys(labelled)) -- [disc | hidden],
        Map.get(labelled, name) != Map.get(plugin, name),
        do: {variant, name, {Map.get(labelled, name), Map.get(plugin, name)}}
  end

  defp disc({_tag, [{key, _value}]}), do: key
  defp disc([{key, _value}]), do: key
  defp disc(tag) when is_binary(tag), do: nil

  defp result(gaps) do
    case for({key, [_ | _] = found} <- gaps, into: %{}, do: {key, Enum.sort(Enum.uniq(found))}) do
      empty when map_size(empty) == 0 -> :ok
      found -> {:error, found}
    end
  end
end
