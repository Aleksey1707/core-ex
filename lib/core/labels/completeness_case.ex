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
  struct'ы, списки и варианты семейства. Автор события (`by`) в сведения не выходит, но событие
  страницы событий с подписями (`Core.Web.Event`, `labels: true` требует `user_ref:`) дампит его
  ссылкой на учётную запись с именем из словаря ссылок, а словарь находит только id с резолвером —
  иначе `ArgumentError` на первом событии. Ключи и значения свободной map'ы (`type: :map`) спеки
  нет, и вид id в них ратчет не видит: его проверяет только построение сведений.

  ## Генерируемые тесты

  1. обход находит хотя бы одно событие: ратчет, который ничего не нашёл, не проходит. Числовых
     нижних границ нет — их пришлось бы двигать с каждым событием;
  2. у каждого события название (`Core.Labels.Event`);
  3. автор каждого события (`__es_by__/0`) — Prim с `use Core.Labels.ID, kind: :user` и `resolver:`;
     пробел — `{событие, :by, Prim автора}`;
  4. у каждого struct'а, достижимого из нагрузки, — нагрузки, вложенного struct'а, варианта
     семейства — решение по полям (`Core.Labels.Fields`);
  5. у каждого Enum, достижимого из нагрузки, подписи значений (`Core.Labels.Values`);
  6. у каждого Prim-идентификатора, достижимого из нагрузки, вид (`Core.Labels.ID`) или текст
     (`Core.Labels.Text`) — свой или базы композита;
  7. спека видимых полей `fields:` каждого варианта семейства с подписями совпадает со спекой его
     плагина (`variants:`): иначе подписи варианта разошлись бы с его wire-формой. Поле-дискриминатор
     в спеку плагина не входит и не сверяется. Семейство поля `union:` без плагина среди модулей
     `otp_app:` — провал, даже если плагин лежит в другом приложении: его вариантов обход не знает.

  Логика теста — функция `check_*` (`:ok | {:error, пробелы}`), сам тест — `assert :ok = …`:
  провал перечисляет все пробелы разом, с модулем-владельцем, полем и модулем без объявления.

  ## Opts

  - `otp_app:` — приложение, чьи модули проверяются, обязательная; не загружено — провал всех тестов
  - `async:` — опция `ExUnit.Case`, необязательная, по умолчанию `true`; явное значение требует
    `Credo.Check.Refactor.PassAsyncInTestCases`
  """

  alias Core.Codec.Field
  alias Core.Helper
  alias Core.Labels.Fields
  alias Core.Labels.ID
  alias Core.Labels.Kind
  alias Core.Result

  @label "Labels.CompletenessCase"
  @required_keys ~w(otp_app)a
  @optional_keys ~w(async)a

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

  @typedoc "Prim-идентификаторы без вида."
  @type unkinded :: %{unkinded: [place()]}

  @typedoc """
  Варианты, чья спека поля расходится со спекой плагина (`{подписи, плагин}`, `nil` — спеки нет), и
  семейства без плагина.
  """
  @type variants :: %{
          optional(:diverged) => [{module(), atom(), {Fields.spec() | nil, Fields.spec() | nil}}],
          optional(:unknown_family) => [place()]
        }

  # ===== объявление =====

  @doc "Сгенерировать тесты полноты подписей приложения."
  defmacro __using__(opts) do
    lit = Macro.expand_literals(opts, __CALLER__)
    Helper.Opts.validate!(lit, @required_keys, @optional_keys, @label)
    otp_app = Helper.Opts.atom!(lit, :otp_app, @label)
    async = async!(lit)

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
        raise CompileError, description: "#{@label}: async: ожидается boolean, получено #{inspect(other)}"
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
    case walk(modules).events do
      [] -> {:error, :empty}
      [_ | _] -> :ok
    end
  end

  @doc false
  @spec check_titles([module()]) :: Result.unit(untitled())

  def check_titles(modules) when is_list(modules) do
    result(
      untitled: for(event <- walk(modules).events, not Helper.Module.exports?(event, :__label_title__, 0), do: event)
    )
  end

  @doc false
  @spec check_authors([module()]) :: Result.unit(unnamed())

  def check_authors(modules) when is_list(modules) do
    unnamed = for event <- walk(modules).events, by = event.__es_by__(), not user?(by), do: {event, :by, by}

    result(unnamed: unnamed)
  end

  @doc false
  @spec check_fields([module()]) :: Result.unit(undecided())

  def check_fields(modules) when is_list(modules) do
    undecided =
      for {:struct, owner, field, module} <- walk(modules).places,
          not Fields.labelled?(module),
          do: {owner, field, module}

    result(undecided: undecided)
  end

  @doc false
  @spec check_values([module()]) :: Result.unit(unlabelled())

  def check_values(modules) when is_list(modules) do
    unlabelled =
      for {:enum, owner, field, module} <- walk(modules).places,
          not Helper.Module.exports?(module, :labels, 0),
          do: {owner, field, module}

    result(unlabelled: unlabelled)
  end

  @doc false
  @spec check_ids([module()]) :: Result.unit(unkinded())

  def check_ids(modules) when is_list(modules) do
    unkinded =
      for {:prim, owner, field, module} <- walk(modules).places, unkinded?(module), do: {owner, field, module}

    result(unkinded: unkinded)
  end

  @doc false
  @spec check_variants([module()]) :: Result.unit(variants())

  def check_variants(modules) when is_list(modules) do
    unknown = for {:family, owner, field, family} <- walk(modules).places, do: {owner, field, family}

    diverged =
      for plugin <- modules,
          Helper.Module.exports?(plugin, :__codec_variants__, 0),
          {variant, address, fields} when is_list(fields) <- plugin.__codec_variants__(),
          Fields.labelled?(variant),
          gap <- diverged(variant, disc(address), fields),
          do: gap

    result(diverged: diverged, unknown_family: unknown)
  end

  # ---

  # Обход от событий кодеков: места `{вид, владелец, поле, модуль}`, где нагрузка достигает модуля.
  defp walk(modules) do
    families =
      for plugin <- modules,
          Helper.Module.exports?(plugin, :__codec_union__, 0),
          family = plugin.__codec_union__(),
          reduce: %{} do
        acc -> Map.update(acc, family, [plugin], &[plugin | &1])
      end

    events =
      for codec <- modules,
          Core.Es.Event.Codec.codec?(codec),
          event <- codec.__es_mods__(),
          uniq: true,
          do: event

    {places, _seen} = Enum.reduce(events, {[], MapSet.new()}, &visit_event(&1, &2, families))

    %{events: Enum.sort(events), places: places}
  end

  defp visit_event(event, acc, families) do
    case event.__es_payload__() do
      nil -> acc
      payload -> visit(event, :payload, payload_spec(payload), acc, families)
    end
  end

  defp payload_spec(payload) do
    if Core.Prim.prim?(payload), do: {:prim, payload}, else: {:entity, payload}
  end

  defp visit(owner, field, {kind, module}, acc, _families) when kind in ~w(prim enum)a,
    do: place(acc, {kind, owner, field, module})

  defp visit(owner, field, {:list, inner}, acc, families), do: visit(owner, field, inner, acc, families)

  defp visit(owner, field, {:entity, module}, acc, families),
    do: descend(place(acc, {:struct, owner, field, module}), module, families)

  defp visit(owner, field, {:union, family}, acc, families) do
    case Map.fetch(families, family) do
      {:ok, plugins} ->
        plugins
        |> Enum.flat_map(& &1.__codec_types__())
        |> Enum.reduce(acc, &visit(owner, field, {:entity, &1}, &2, families))

      :error ->
        place(acc, {:family, owner, field, family})
    end
  end

  defp visit(_owner, _field, _spec, acc, _families), do: acc

  defp place({places, seen}, place), do: {[place | places], seen}

  defp descend({places, seen} = acc, module, families) do
    if MapSet.member?(seen, module) or not Fields.labelled?(module) do
      acc
    else
      module
      |> Fields.visible()
      |> Enum.reduce({places, MapSet.put(seen, module)}, fn {name, spec}, acc ->
        visit(module, name, spec, acc, families)
      end)
    end
  end

  defp user?(module), do: match?(%{kind: :user}, ID.find(module))

  defp unkinded?(module), do: match?({:unkinded, _leaf}, Kind.of(module))

  defp diverged(variant, disc, fields) do
    plugin = Map.new(fields, fn %Field{name: name, spec: spec} -> {name, spec} end)
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
