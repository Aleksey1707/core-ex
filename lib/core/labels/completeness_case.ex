defmodule Core.Labels.CompletenessCase do
  @moduledoc """
  Case-модуль полноты подписей: у каждого события приложения название, у каждого struct'а, Enum и
  id, достижимых из нагрузки, — объявление (ADR-0063).

      defmodule MyApp.Labels.CompletenessTest do
        use Core.Labels.CompletenessCase,
          app: :my_app,
          async: true
      end

  Один тест-модуль на приложение поверх `ExUnit.Case`. Сборка объявлений видит один модуль: событие
  без `use Core.Labels.Event` собирается, Enum без `use Core.Labels.Values` и id без
  `use Core.Labels.ID` — тоже, а сведения по ним ломаются только на странице событий. Поэтому
  полнота держится тестом на всё дерево, а не сборкой.

  Модули приложения перечисляет `:application.get_key/2`. Кодеки — модули с `__es_mods__/0`
  (`use Core.Es.Event.Codec`), семейства — плагины с `__codec_union__/0` (`use Core.Codec.Plugin,
  union:`). Перечня нет: новый кодек попадает под проверку сам, без новой строки теста. Обход идёт от
  событий кодеков по спеке нагрузки (`Core.Labels.Fields`): во вложенные struct'ы, списки и варианты
  семейства. Автор события (`by`) в сведения не выходит и не проверяется. Ключи и значения свободной
  map'ы (`type: :map`) спеки нет, и вид id в них ратчет не видит: его проверяет только построение
  сведений.

  ## Генерируемые тесты

  1. обход находит хотя бы одно событие: ратчет, который ничего не нашёл, не проходит. Числовых
     нижних границ нет — их пришлось бы двигать с каждым событием;
  2. у каждого события название (`Core.Labels.Event`);
  3. у каждого struct'а, достижимого из нагрузки, — нагрузки, вложенного struct'а, варианта
     семейства — решение по полям (`Core.Labels.Fields`);
  4. у каждого Enum, достижимого из нагрузки, подписи значений (`Core.Labels.Values`);
  5. у каждого Prim-идентификатора, достижимого из нагрузки, вид (`Core.Labels.ID`) или текст
     (`Core.Labels.Text`) — свой или базы композита;
  6. спека видимых полей `fields:` каждого варианта семейства с подписями совпадает со спекой его
     плагина (`variants:`): иначе подписи варианта разошлись бы с его wire-формой. Поле-дискриминатор
     в спеку плагина не входит и не сверяется. Семейство поля `union:` без плагина среди модулей
     `app:` — провал, даже если плагин лежит в другом приложении: его вариантов обход не знает.

  Логика теста — функция `check_*` (`:ok | {:error, пробелы}`), сам тест — `assert :ok = …`:
  провал перечисляет все пробелы разом, с модулем-владельцем, полем и модулем без объявления.

  ## Opts

  - `app:` — приложение, чьи модули проверяются, обязательная; не загружено — провал всех тестов
  - `async:` — опция `ExUnit.Case`, необязательная, по умолчанию `true`; явное значение требует
    `Credo.Check.Refactor.PassAsyncInTestCases`
  """

  alias Core.Helper
  alias Core.Labels.Fields
  alias Core.Labels.ID
  alias Core.Labels.Text

  @label "Labels.CompletenessCase"
  @required_keys ~w(app)a
  @optional_keys ~w(async)a

  @typedoc "Пробел: модуль-владелец, поле и модуль значения без объявления."
  @type place :: {module(), atom(), module()}

  @typedoc "События без названия."
  @type untitled :: %{untitled: [module()]}

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
    app = Helper.Opts.atom!(lit, :app, @label)
    async = async!(lit)

    quote do
      use ExUnit.Case, async: unquote(async)

      setup_all do
        %{modules: Core.Labels.CompletenessCase.modules!(unquote(app))}
      end

      test "обход находит события", %{modules: modules} do
        assert :ok = Core.Labels.CompletenessCase.check_found(modules)
      end

      test "у каждого события название", %{modules: modules} do
        assert :ok = Core.Labels.CompletenessCase.check_titles(modules)
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
  @spec check_found([module()]) :: :ok | {:error, :empty}

  def check_found(modules) when is_list(modules) do
    case walk(modules).events do
      [] -> {:error, :empty}
      [_ | _] -> :ok
    end
  end

  @doc false
  @spec check_titles([module()]) :: :ok | {:error, untitled()}

  def check_titles(modules) when is_list(modules) do
    result(untitled: for(event <- walk(modules).events, not exports?(event, :__label_title__), do: event))
  end

  @doc false
  @spec check_fields([module()]) :: :ok | {:error, undecided()}

  def check_fields(modules) when is_list(modules) do
    undecided =
      for {:struct, owner, field, module} <- walk(modules).places,
          not exports?(module, :__label_fields__),
          do: {owner, field, module}

    result(undecided: undecided)
  end

  @doc false
  @spec check_values([module()]) :: :ok | {:error, unlabelled()}

  def check_values(modules) when is_list(modules) do
    unlabelled =
      for {:enum, owner, field, module} <- walk(modules).places,
          not exports?(module, :labels),
          do: {owner, field, module}

    result(unlabelled: unlabelled)
  end

  @doc false
  @spec check_ids([module()]) :: :ok | {:error, unkinded()}

  def check_ids(modules) when is_list(modules) do
    unkinded =
      for {:prim, owner, field, module} <- walk(modules).places, unkinded?(module), do: {owner, field, module}

    result(unkinded: unkinded)
  end

  @doc false
  @spec check_variants([module()]) :: :ok | {:error, variants()}

  def check_variants(modules) when is_list(modules) do
    unknown = for {:family, owner, field, family} <- walk(modules).places, do: {owner, field, family}

    diverged =
      for plugin <- modules,
          exports?(plugin, :__codec_variants__),
          {variant, address, fields} when is_list(fields) <- plugin.__codec_variants__(),
          exports?(variant, :__label_fields__),
          gap <- diverged(variant, disc(address), fields),
          do: gap

    result(diverged: diverged, unknown_family: unknown)
  end

  # ---

  # Обход от событий кодеков: места `{вид, владелец, поле, модуль}`, где нагрузка достигает модуля.
  defp walk(modules) do
    families =
      for plugin <- modules, exports?(plugin, :__codec_union__), family = plugin.__codec_union__(), reduce: %{} do
        acc -> Map.update(acc, family, [plugin], &[plugin | &1])
      end

    events = for codec <- modules, exports?(codec, :__es_mods__), event <- codec.__es_mods__(), uniq: true, do: event
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
    if MapSet.member?(seen, module) or not exports?(module, :__label_fields__) do
      acc
    else
      module
      |> specs()
      |> Enum.reduce({places, MapSet.put(seen, module)}, fn {name, spec}, acc ->
        visit(module, name, spec, acc, families)
      end)
    end
  end

  defp specs(module) do
    case Fields.change(module) do
      nil -> Fields.specs(module)
      {_label, spec} -> [old_value: spec, new_value: spec]
    end
  end

  defp unkinded?(module) do
    cond do
      ID.find(module) != nil or Text.find(module) != nil -> false
      Core.Prim.composed?(module) -> unkinded?(module.__domain_base__())
      true -> module.__domain_kind__() == :uuid
    end
  end

  defp diverged(variant, disc, fields) do
    plugin = Map.new(fields, fn {name, spec, _optional?, _wire, _default} -> {name, spec} end)
    labelled = Map.new(Fields.specs(variant))
    hidden = for {name, :hidden} <- variant.__label_fields__(), do: name

    for name <- Enum.uniq(Map.keys(plugin) ++ Map.keys(labelled)) -- [disc | hidden],
        Map.get(labelled, name) != Map.get(plugin, name),
        do: {variant, name, {Map.get(labelled, name), Map.get(plugin, name)}}
  end

  defp disc({_tag, [{key, _value}]}), do: key
  defp disc([{key, _value}]), do: key
  defp disc(tag) when is_binary(tag), do: nil

  # `function_exported?/3` не грузит модуль: ещё не загруженный выпал бы из обхода молча.
  defp exports?(module, fun), do: Code.ensure_loaded?(module) and function_exported?(module, fun, 0)

  defp result(gaps) do
    case for({key, [_ | _] = found} <- gaps, into: %{}, do: {key, Enum.sort(Enum.uniq(found))}) do
      empty when map_size(empty) == 0 -> :ok
      found -> {:error, found}
    end
  end
end
