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
  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(opts, ~w(types)a, ~w(loadable union)a, "Codec.Plugin")

      @behaviour Core.Codec.Plugin

      @codec_types Core.Codec.Plugin.Opts.types!(opts)
      @codec_loadable Keyword.get(opts, :loadable, true)
      @codec_union Core.Codec.Plugin.Opts.union!(opts, @codec_loadable)

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

      @after_compile {Core.Codec.Plugin.Opts, :after_compile!}
    end
  end
end
