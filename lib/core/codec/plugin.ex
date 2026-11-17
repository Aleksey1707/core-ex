defmodule Core.Codec.Plugin do
  @moduledoc """
  Behaviour entity-кодека (плагин фасада `Core.Codec.Facade`).

  Плагин не хардкодит Prim-профиль: вложенные значения сериализует через
  переданный `codec` (модуль с `Core.Codec.Facade.Behaviour`).

  `use` импортирует хелперы: `field/2` (`Core.Helper.Map`), `dump_optional/2` /
  `dump_many/2` / `dump_raw/3` / `load_optional/3` / `load_many/3` (`Core.Codec.Helper`).

  `dump_raw/3` — для плагинов read-моделей: значения во View лежат без Prim-обёртки,
  а формат должен совпадать с Prim-путём (`13-repos.md`).

  ## Декларативные типы (`types:`)

  Тип, чья wire-форма повторяет его поля один к одному, объявляется декларацией (`use Core.Struct`,
  `use Core.Es.Event.Payload`, `use Core.Es.ValueChanged`) и экспортирует `__core_fields__/0`.
  `types:` только регистрирует такие типы: `dump/2` и `load/3` плагин генерирует по IR
  (`Core.Codec.Plugin.Fields`) — вид поля, wire-ключ, `optional:` и типизированный `default:`
  берутся из одной декларации.

  ```elixir
  defmodule Item do
    use Core.Struct,
      fields: [
        id: [prim: Item.ID],
        name: [prim: Item.Name, wire: "title"],
        note: [prim: Item.Note, optional: true],
        status: [enum: Item.Status, default: :new],
        tags: [list: [entity: Item.Tag]]
      ]
  end

  use Core.Codec.Plugin, types: [Item]
  ```

  `personal:` и `subject:` декларации на Codec не влияют: значения остаются открытыми, маркеры ПДн
  ставит нагрузка события. `default:` подставляется только при отсутствующем wire-ключе и уже
  типизированным значением; явный `null` его не заменяет — у `optional: true` это `nil`, у
  обязательного поля ошибка загрузки.

  ## Ручные типы

  Тип без декларации требует ручных клауз `dump/2` и (при `loadable: true`) `load/3` — форму wire
  задаёт автор типа. Если нужна пере-дамп-спека, он же объявляет `redump_spec/1`. Смешанный плагин
  (часть типов декларативные, часть ручные) допустим. Ручная клауза на декларативный тип — `CompileError`
  «never match»: её перекрывает сгенерированная.

  ## Семейство вариантов (`union:`)

  Полиморфный wire (тег внутри данных) восстанавливается не отдельной функцией фасада,
  а по **модулю-семейству**: `codec.load(<Aggregate>.Event, data)`. Плагин объявляет его
  опцией `union:`, фасад заводит для него клоузу `load/2`, а какой конкретно тип лежит в
  данных — решает плагин. Так у фасада остаётся одна ось диспетчеризации — модуль.

  Состав и адреса вариантов объявляет модуль семейства (`use Core.Union`), плагин читает реестр
  `__core_variants__/0` и генерирует `dump/2` / `load/3` каждого варианта и загрузку семейства по
  адресу (`Core.Codec.Plugin.Variants`). Поля декларативного варианта — из его `__core_fields__/0`,
  вариант-Prim дампится и грузится своим кодеком (`"fields"` — дамп Prim), ручной вариант — колбэками
  `dump_variant/2` / `load_variant/3`. Семейство без реестра (например, кодек событий) пишет
  `load/3` семейства само.

  ## Протокол фасада

  Две служебные функции плагина фасад зовёт при своей сборке, и о видах плагинов он не знает:

  - `__codec_pattern__/1` — паттерн, которым фасад сужает результат `load/2` / `load!/2` для типа
    плагина; по умолчанию `%Type{}`;
  - `__codec_check__/1` — проверка плагина против полного списка плагинов фасада, отказ —
    `CompileError`; по умолчанию проверять нечего.

  `use` генерирует обе по умолчанию, плагин MAY переопределить их (образец — кодек событий:
  сужение по нагрузке, уникальность типа агрегата и обслуживание нагрузок-сущностей).

  ## Спека пере-дампа

  Спеку `Core.Codec.Redump` каждого декларативного типа и варианта семейства плагин выводит сам и
  отдаёт служебной `__codec_redump__/1` (`Core.Codec.Plugin.Redump`): тип по полям —
  `{:map, %{wire-ключ => спека}}`, вариант — форма его дампа, семейство — слияние спек вариантов.
  Ручной тип, ручной вариант (спека его полей) и семейство без реестра объявляют спеку колбэком
  `redump_spec/1`; клауза колбэка на тип с выведенной спекой — `CompileError`.
  `__codec_redump__/1` генерируется только на типы со спекой, типы без неё отдаёт
  `__codec_redump_missing__/0`, и отказ по ним бросает фасад.

  ## Опции

  - `types:` — опция-выражение (`docs/rules/20-agreements.md`, «Опции `use`»): список вычисляется в
    теле плагина, поэтому законно `types: Map.keys(@tag_by_mod)`
  - `loadable:` — `true` (default), если есть `load/3`; `false` — только `dump/2`
  - `union:` — модуль-семейство вариантов (`use Core.Union`)

  Ключи, `loadable:` и `union:` проверяются при раскрытии `use`; атрибут или вызов функции в
  литеральной опции — `CompileError` «ожидается литерал». `fields:` и `variants:` — неизвестные
  опции: поля и адреса объявляются в декларации типа и в модуле семейства.

  Декларативный тип MUST быть собран выше `use` (в том же модуле или отдельным модулем): плагин
  читает его `__core_fields__/0` при раскрытии. Модуль `types:` без декларации плагин не проверяет —
  его обслуживает ручная клауза.
  """

  alias Core.Helper
  alias Core.Result

  @label "Codec.Plugin"
  @required_keys ~w()a
  @optional_keys ~w(types loadable union)a
  @expression_keys ~w(types)a

  @typedoc "Модуль entity-фасада (`Core.Codec.Facade.Behaviour`)."
  @type codec :: module()

  @doc "Модули struct, обслуживаемые `dump/2` и (опционально) `load/3`."
  @callback __codec_types__() :: [module()]

  @doc "Модуль-семейство для `load/3` по тегу внутри данных; `nil`, если его нет."
  @callback __codec_union__() :: module() | nil

  @doc "Domain struct → wire."
  @callback dump(struct(), codec()) :: term()

  @doc "Модуль (тип или семейство) + wire → domain (опционально при `loadable: false`)."
  @callback load(module(), term(), codec()) :: Result.t()

  @doc "Поля ручного варианта семейства (`kind: :manual` в `Core.Union`) → map; адрес и обёртку пишет плагин."
  @callback dump_variant(struct(), codec()) :: map()

  @doc "Модуль ручного варианта + его поля → вариант; адрес уже сверен плагином."
  @callback load_variant(module(), map(), codec()) :: Result.t(struct())

  @doc """
  Спека пере-дампа (`Core.Codec.Redump`) ручного типа, ручного варианта (спека его полей, `{:map, _}`)
  или семейства `union:` без реестра вариантов; спеку декларативных типов и вариантов выводит плагин.
  """
  @callback redump_spec(module()) :: Core.Codec.Redump.spec()

  @doc false
  @callback __codec_pattern__(type :: module()) :: Macro.t()

  @doc false
  @callback __codec_check__(plugins :: [module()]) :: :ok

  @optional_callbacks load: 3, dump_variant: 2, load_variant: 3, redump_spec: 1

  @doc """
  Объявить entity-плагин.

  ## Opts

  - `types:` — список модулей, которые обслуживает плагин. Декларативный тип (экспортирует
    `__core_fields__/0`) получает `dump/2`/`load/3` и redump-спеку по общей декларации; тип без
    неё требует ручных клауз `dump/2`/`load/3` (и `redump_spec/1`, если нужна пере-дамп-спека)
  - `loadable:` — `true` (default), если есть `load/3`; `false` — только `dump/2`
  - `union:` — модуль-семейство вариантов: состав берётся из `__core_variants__/0` (`use Core.Union`),
    фасад отдаёт семейству `load/3` по адресу внутри данных

  Поля в плагине не объявляются: их источник — `__core_fields__/0` типа. `fields:` и `variants:` —
  неизвестные опции (`CompileError`).
  """
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)
    loadable = Core.Codec.Plugin.Opts.loadable!(opts)
    union = Core.Codec.Plugin.Opts.union!(opts, loadable)

    [
      quote do
        @behaviour Core.Codec.Plugin

        @codec_loadable unquote(loadable)
        @codec_union unquote(union)
        @codec_declared_types Core.Codec.Plugin.Opts.types!(unquote(Keyword.get(opts, :types, [])))
        @codec_variants Core.Codec.Plugin.Variants.union_variants(@codec_union)
        @codec_declared Core.Codec.Plugin.Opts.declared!(@codec_declared_types)
        @codec_types Core.Codec.Plugin.Opts.all_types!([
                       @codec_declared_types,
                       Enum.map(@codec_variants, &elem(&1, 0))
                     ])
      end,
      quote unquote: false do
        # `@impl` и на колбэках `__codec_*__`, и на сгенерированных клаузах: ручная клауза с `@impl` у
        # смешанного плагина иначе требует его от каждого колбэка из этого `use`.
        @doc false
        @spec __codec_types__() :: [module()]

        @impl true
        def __codec_types__, do: @codec_types

        @doc false
        @spec __codec_loadable__() :: boolean()

        def __codec_loadable__, do: @codec_loadable

        @doc false
        @spec __codec_union__() :: module() | nil

        @impl true
        def __codec_union__, do: @codec_union

        @doc false
        @spec __codec_pattern__(module()) :: Macro.t()

        @impl true
        def __codec_pattern__(type) when is_atom(type), do: quote(do: %unquote(type){})

        @doc false
        @spec __codec_check__([module()]) :: :ok

        @impl true
        def __codec_check__(plugins) when is_list(plugins), do: :ok

        defoverridable __codec_pattern__: 1, __codec_check__: 1

        import Core.Helper.Map, only: [field: 2]

        import Core.Codec.Helper,
          only: [
            dump_optional: 2,
            dump_many: 2,
            dump_raw: 3,
            load_optional: 3,
            load_many: 3
          ]

        for {type, fields} <- @codec_declared do
          @impl true
          def dump(unquote_splicing(Core.Codec.Plugin.Fields.dump_args_ir(type, fields)))
              when unquote(Core.Codec.Plugin.Fields.dump_guard_ir(fields)),
              do: unquote(Core.Codec.Plugin.Fields.dump_body_ir(fields))
        end

        for variant <- @codec_variants do
          @impl true
          def dump(unquote_splicing(Core.Codec.Plugin.Variants.dump_args(variant)))
              when unquote(Core.Codec.Plugin.Variants.dump_guard(variant)),
              do: unquote(Core.Codec.Plugin.Variants.dump_body(variant))
        end

        for {type, fields} <- @codec_declared, @codec_loadable do
          @impl true
          def load(unquote_splicing(Core.Codec.Plugin.Fields.load_args(type)))
              when unquote(Core.Codec.Plugin.Fields.load_guard()),
              do: unquote(Core.Codec.Plugin.Fields.load_body_ir(type, fields))
        end

        for {type, _address, _place, _fields} = variant <- @codec_variants do
          @impl true
          def load(unquote_splicing(Core.Codec.Plugin.Variants.load_args(type)))
              when unquote(Core.Codec.Plugin.Variants.load_guard()),
              do: unquote(Core.Codec.Plugin.Variants.load_body(variant))
        end

        if @codec_variants != [] do
          @impl true
          def load(unquote_splicing(Core.Codec.Plugin.Variants.load_args(@codec_union)))
              when unquote(Core.Codec.Plugin.Variants.load_guard()),
              do:
                unquote(
                  Core.Codec.Plugin.Variants.family_body(
                    @codec_union,
                    Core.Codec.Plugin.Variants.index(@codec_variants)
                  )
                )

          for variant <- @codec_variants do
            defp __codec_variant__(unquote_splicing(Core.Codec.Plugin.Variants.variant_args(variant)))
                 when unquote(Core.Codec.Plugin.Variants.variant_guard(variant)),
                 do: unquote(Core.Codec.Plugin.Variants.variant_body(variant))
          end

          @codec_type_by_mod Core.Codec.Plugin.Variants.type_by_mod(@codec_variants)

          @doc "Wire-тег варианта по struct или модулю (у адреса без обёртки — значение дискриминатора)."
          @spec type(struct() | module()) :: String.t()

          def type(%mod{}) when is_map_key(@codec_type_by_mod, mod), do: Map.fetch!(@codec_type_by_mod, mod)

          def type(mod) when is_atom(mod) and is_map_key(@codec_type_by_mod, mod),
            do: Map.fetch!(@codec_type_by_mod, mod)

          @doc "Множество wire-тегов вариантов."
          @spec types() :: MapSet.t(String.t())

          def types, do: MapSet.new(Map.values(@codec_type_by_mod))
        end

        @before_compile Core.Codec.Plugin.Opts
        @before_compile Core.Codec.Plugin.Redump
      end
    ]
  end
end
