defmodule Core.Codec.Plugin do
  @moduledoc """
  Behaviour entity-кодека (плагин фасада `Core.Codec.Facade`).

  Плагин не хардкодит Prim-профиль: вложенные значения сериализует через
  переданный `codec` (модуль с `Core.Codec.Facade.Behaviour`).

  `use` импортирует хелперы: `field/2` (`Core.Helper.Map`), `dump_optional/2` /
  `dump_many/2` / `dump_raw/3` / `load_optional/3` / `load_many/3` (`Core.Codec.Helper`).

  `dump_raw/3` — для плагинов read-моделей: значения во View лежат без Prim-обёртки,
  а формат должен совпадать с Prim-путём (`13-repos.md`).

  ## Семейство типов (`union:`)

  Полиморфный wire (тег внутри данных) восстанавливается не отдельной функцией фасада,
  а по **модулю-семейству**: `codec.load(<Aggregate>.Event, data)`. Плагин объявляет его
  опцией `union:`, фасад заводит для него клоузу `load/2`, а какой конкретно тип лежит в
  данных — решает сам плагин. Так у фасада остаётся одна ось диспетчеризации — модуль.

  Варианты, которые узнаются по адресу в данных, объявляются `variants:`, и разбор генерирует
  плагин (`Core.Codec.Plugin.Variants`):

  ```elixir
  use Core.Codec.Plugin,
    union: Shape,
    variants: [
      {Shape.Circle, "circle", radius: [type: :pos_integer]},
      {Shape.Rect, {"polygon", kind: :rect}, width: [type: :pos_integer], height: [type: :pos_integer]},
      {Shape.Blob, "blob"}
    ]
  ```

  Ручной вариант (`{Type, адрес}`) пишет только поля — колбэками `dump_variant/2` / `load_variant/3`.

  ## Протокол фасада

  Две служебные функции плагина фасад зовёт при своей сборке, и о видах плагинов он не знает:

  - `__codec_pattern__/1` — паттерн, которым фасад сужает результат `load/2` / `load!/2` для типа
    плагина; по умолчанию `%Type{}`;
  - `__codec_check__/1` — проверка плагина против полного списка плагинов фасада, отказ —
    `CompileError`; по умолчанию проверять нечего.

  `use` генерирует обе по умолчанию, плагин MAY переопределить их (образец — кодек событий:
  сужение по нагрузке, уникальность типа агрегата и обслуживание нагрузок-сущностей).

  ## Спека пере-дампа

  Спеку `Core.Codec.Redump` каждого типа из `fields:`, варианта из `variants:` и семейства с
  `variants:` плагин выводит сам и отдаёт служебной `__codec_redump__/1` (`Core.Codec.Plugin.Redump`):
  тип по полям — `{:map, %{wire-ключ => спека}}`, вариант — форма его дампа, семейство — слияние спек
  вариантов. Ручной тип, ручной вариант (спека его полей) и семейство без `variants:` объявляют спеку
  колбэком `redump_spec/1`; клауза колбэка на тип с выведенной спекой — `CompileError`.
  `__codec_redump__/1` генерируется только на типы со спекой, типы без неё отдаёт
  `__codec_redump_missing__/0`, и отказ по ним бросает фасад.

  ## Плагин по полям (`fields:`)

  Тип, чья wire-форма повторяет поля один к одному, объявляется спекой полей, и `dump/2` /
  `load/3` для него генерируются (`Core.Codec.Plugin.Fields`):

  ```elixir
  use Core.Codec.Plugin,
    fields: [
      {Item,
       id: [prim: Item.ID],
       name: [prim: Item.Name, wire: "title"],
       note: [prim: Item.Note, optional: true],
       status: [enum: Item.Status, default: "new"],
       tags: [list: [entity: Item.Tag]]}
    ]
  ```

  Поле — ровно один вид: `prim:` (любой Prim), `enum:` (`Core.Enum`), `entity:` (struct фасада),
  `union:` (вариант семейства: дамп в форме адреса, загрузка `codec.load(Family, raw)`, голова —
  только `is_struct`), `list:` (спека элемента), `type:` (как у `Core.View`: скаляр или `:map`); плюс
  `optional: true`, `wire: "ключ"` (по умолчанию имя поля строкой) и `default:` — wire-литерал
  вместо отсутствующего ключа или `nil` при загрузке.
  Ключи спеки сверяются с полями struct без `__struct__` и `events`; расхождение — `CompileError`.
  `load/3` собирает struct литералом; первая ошибка поля — итог, лишние ключи игнорируются.
  Дамп — map со строковыми ключами. Ручная клауза на тип из `fields:` и `@spec` у `dump/2` /
  `load/3` такого плагина — `CompileError`. Тип из `fields:` в `types:` не повторяется: `types:` —
  только ручные типы.

  ## Опции

  `types:` — опция-выражение (`docs/rules/20-agreements.md`, «Опции `use`»): список вычисляется в теле
  плагина, поэтому законно `types: Map.keys(@tag_by_mod)`. Остальные опции — литералы: ключи,
  `loadable:` и `union:` проверяются при раскрытии `use`, атрибут или вызов функции — `CompileError`
  «ожидается литерал».

  Модули `types:` / `fields:` / `variants:` MAY быть вложены в плагин: проверки по ним (struct, поля,
  Prim) идут в теле. Вложенный модуль `fields:` / `variants:` MUST быть объявлен выше `use` — ниже он
  ещё не собран, и сборка падает `CompileError` «недоступен». Модуль `types:` при сборке плагина не
  проверяется: его может объявлять сам вызывающий (кодек View вложен в своё представление).
  """

  alias Core.Helper
  alias Core.Result

  @label "Codec.Plugin"
  @required_keys ~w()a
  @optional_keys ~w(types loadable union fields variants)a
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

  @doc "Поля ручного варианта (`{Mod, адрес}` в `variants:`) → map; адрес и обёртку пишет плагин."
  @callback dump_variant(struct(), codec()) :: map()

  @doc "Модуль ручного варианта + его поля → вариант; адрес уже сверен плагином."
  @callback load_variant(module(), map(), codec()) :: Result.t(struct())

  @doc """
  Спека пере-дампа (`Core.Codec.Redump`) ручного типа, ручного варианта (спека его полей, `{:map, _}`)
  или семейства `union:` без `variants:`; спеку типов из `fields:` / `variants:` выводит плагин.
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

  - `types:` — список модулей struct с ручными `dump/2` / `load/3`
  - `loadable:` — `true` (default), если есть `load/3`; `false` — только `dump/2`
  - `union:` — модуль-семейство типов: фасад отдаёт ему `load/3` с тегом внутри данных
  - `fields:` — список пар `{Type, spec}`: типы, для которых `dump/2` / `load/3` генерируются
    по спеке полей
  - `variants:` — варианты семейства `union:`: `{Type, адрес, spec}` или `{Type, адрес}`
    (`Core.Codec.Plugin.Variants`)

  Тип объявляется ровно одной из `types:` / `fields:` / `variants:`; хотя бы одна из них обязательна.
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
        @codec_fields Core.Codec.Field.fields!(unquote(Macro.escape(Keyword.get(opts, :fields))), @codec_loadable)
        @codec_variants Core.Codec.Plugin.Variants.variants!(
                          unquote(Macro.escape(Keyword.get(opts, :variants))),
                          @codec_union
                        )
        @codec_types Core.Codec.Plugin.Opts.all_types!([
                       Core.Codec.Plugin.Opts.types!(unquote(Keyword.get(opts, :types, []))),
                       Enum.map(@codec_fields, &elem(&1, 0)),
                       Enum.map(@codec_variants, &elem(&1, 0))
                     ])
      end,
      quote unquote: false do
        @codec_variants_info Core.Codec.Plugin.Variants.introspection(@codec_variants)

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
        @spec __codec_variants__() :: [{module(), term(), [Core.Codec.Field.t()] | :manual}]

        def __codec_variants__, do: @codec_variants_info

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

        for {type, fields} <- @codec_fields do
          @impl true
          def dump(unquote_splicing(Core.Codec.Plugin.Fields.dump_args(type, fields)))
              when unquote(Core.Codec.Plugin.Fields.dump_guard(fields)),
              do: unquote(Core.Codec.Plugin.Fields.dump_body(fields))
        end

        for variant <- @codec_variants do
          @impl true
          def dump(unquote_splicing(Core.Codec.Plugin.Variants.dump_args(variant)))
              when unquote(Core.Codec.Plugin.Variants.dump_guard(variant)),
              do: unquote(Core.Codec.Plugin.Variants.dump_body(variant))
        end

        for {type, fields} <- @codec_fields, @codec_loadable do
          @impl true
          def load(unquote_splicing(Core.Codec.Plugin.Fields.load_args(type)))
              when unquote(Core.Codec.Plugin.Fields.load_guard()),
              do: unquote(Core.Codec.Plugin.Fields.load_body(type, fields))
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
