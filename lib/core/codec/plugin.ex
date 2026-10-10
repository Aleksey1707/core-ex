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

  ## Плагин по полям (`fields:`)

  Тип, чья wire-форма повторяет поля один к одному, объявляется спекой полей, и `dump/2` /
  `load/3` для него генерируются (`Core.Codec.Plugin.Fields`):

  ```elixir
  use Core.Codec.Plugin,
    types: [Item],
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
  `list:` (спека элемента), `type:` (скаляр `Core.View` или `:map`); плюс `optional: true`,
  `wire: "ключ"` (по умолчанию имя поля строкой) и `default:` — wire-литерал вместо отсутствующего
  ключа или `nil` при загрузке.
  Ключи спеки сверяются с полями struct без `__struct__` и `events`; расхождение — `CompileError`.
  `load/3` собирает struct литералом; первая ошибка поля — итог, лишние ключи игнорируются.
  """

  alias Core.Error
  alias Core.Helper

  @typedoc "Модуль entity-фасада (`Core.Codec.Facade.Behaviour`)."
  @type codec :: module()

  @doc "Модули struct, обслуживаемые `dump/2` и (опционально) `load/3`."
  @callback __codec_types__() :: [module()]

  @doc "Модуль-семейство для `load/3` по тегу внутри данных; `nil`, если его нет."
  @callback __codec_union__() :: module() | nil

  @doc "Domain struct → wire."
  @callback dump(struct(), codec()) :: term()

  @doc "Модуль (тип или семейство) + wire → domain (опционально при `loadable: false`)."
  @callback load(module(), term(), codec()) :: {:ok, term()} | {:error, Error.t()}

  @optional_callbacks load: 3

  @doc """
  Объявить entity-плагин.

  ## Opts

  - `types:` — непустой список модулей struct
  - `loadable:` — `true` (default), если есть `load/3`; `false` — только `dump/2`
  - `union:` — модуль-семейство типов: фасад отдаёт ему `load/3` с тегом внутри данных
  - `fields:` — список пар `{Type, spec}`: типы, для которых `dump/2` / `load/3` генерируются
    по спеке полей
  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(opts, ~w(types)a, ~w(loadable union fields)a, "Codec.Plugin")

      @behaviour Core.Codec.Plugin

      @codec_types Core.Codec.Plugin.Opts.types!(opts)
      @codec_loadable Keyword.get(opts, :loadable, true)
      @codec_union Core.Codec.Plugin.Opts.union!(opts, @codec_loadable)
      @codec_fields Core.Codec.Plugin.Fields.fields!(
                      __MODULE__,
                      Keyword.get(opts, :fields),
                      @codec_types,
                      @codec_loadable
                    )

      @doc false
      @spec __codec_types__() :: [module()]

      def __codec_types__, do: @codec_types

      @doc false
      @spec __codec_loadable__() :: boolean()

      def __codec_loadable__, do: @codec_loadable

      @doc false
      @spec __codec_union__() :: module() | nil

      def __codec_union__, do: @codec_union

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
        def dump(unquote_splicing(Core.Codec.Plugin.Fields.dump_args(type, fields)))
            when unquote(Core.Codec.Plugin.Fields.dump_guard(fields)),
            do: unquote(Core.Codec.Plugin.Fields.dump_body(fields))
      end

      for {type, fields} <- @codec_fields, @codec_loadable do
        def load(unquote_splicing(Core.Codec.Plugin.Fields.load_args(type)))
            when unquote(Core.Codec.Plugin.Fields.load_guard()),
            do: unquote(Core.Codec.Plugin.Fields.load_body(type, fields))
      end

      @after_compile {Core.Codec.Plugin.Opts, :after_compile!}
    end
  end
end
