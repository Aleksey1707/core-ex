defmodule Core.Codec.Plugin do
  @moduledoc """
  Behaviour entity-кодека (плагин фасада `Core.Codec.Facade`).

  Плагин не хардкодит Prim-профиль: вложенные значения сериализует через
  переданный `codec` (модуль с `Core.Codec.Facade.Behaviour`).

  `use` импортирует хелперы: `field/2` (`Core.Helper.Map`), `dump_optional/2` /
  `dump_many/2` / `dump_raw_optional/3` / `load_optional/3` / `load_many/3`
  (`Core.Codec.Helper`).

  `dump_raw_optional/3` — для плагинов read-моделей: значения во View лежат без
  Prim-обёртки, а формат должен совпадать с Prim-путём (`13-repos.md`).
  """

  alias Core.Error
  alias Core.Helper

  @typedoc "Модуль entity-фасада (`Core.Codec.Facade.Behaviour`)."
  @type codec :: module()

  @doc "Модули struct, обслуживаемые `dump/2` и (опционально) `load/3`."
  @callback __codec_types__() :: [module()]

  @doc "Domain struct → wire."
  @callback dump(struct(), codec()) :: term()

  @doc "Модуль + wire → domain (опционально при `loadable: false`)."
  @callback load(module(), term(), codec()) :: {:ok, term()} | {:error, Error.t()}

  @doc "Tagged wire (`type` + map) → domain (опционально)."
  @callback load_tagged(String.t(), map(), codec()) :: {:ok, term()} | {:error, Error.t()}

  @optional_callbacks load: 3, load_tagged: 3

  @doc """
  Объявить entity-плагин.

  ## Opts

  - `types:` — список модулей struct (взаимоисключение с `tags:`)
  - `tags:` — `%{Mod => "wire_tag"}` (SSOT: types + tags + `type/1` / `types/0` / `mod_by_tag/1`);
    обязателен при `tagged: true`
  - `loadable:` — `true` (default), если есть `load/3`; `false` — только `dump/2`
  - `tagged:` — `true`, если плагин участвует в `Facade.load_tagged/2` (`load_tagged/3`)
  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(opts, [], ~w(types loadable tagged tags)a, "Codec.Plugin")

      {codec_types, codec_tags, tag_by_mod, from_tags_map?} =
        Core.Codec.Plugin.Opts.normalize!(opts)

      @behaviour Core.Codec.Plugin

      @codec_types codec_types
      @codec_tags codec_tags
      @codec_tag_by_mod tag_by_mod
      @codec_loadable Keyword.get(opts, :loadable, true)
      @codec_tagged Keyword.get(opts, :tagged, false)

      Core.Codec.Plugin.Opts.validate_flags!(@codec_tagged, from_tags_map?)

      @doc false
      @spec __codec_types__() :: [module()]

      def __codec_types__, do: @codec_types

      @doc false
      @spec __codec_loadable__() :: boolean()

      def __codec_loadable__, do: @codec_loadable

      @doc false
      @spec __codec_tagged__() :: boolean()

      def __codec_tagged__, do: @codec_tagged

      @doc false
      @spec __codec_tags__() :: [String.t()]

      def __codec_tags__, do: @codec_tags

      if from_tags_map? do
        @codec_mod_by_tag Map.new(@codec_tag_by_mod, fn {mod, tag} -> {tag, mod} end)

        @doc "Wire-type по struct или модулю."
        @spec type(struct() | module()) :: String.t()

        def type(%mod{}), do: type(mod)

        def type(mod) when is_atom(mod) and is_map_key(@codec_tag_by_mod, mod) do
          Map.fetch!(@codec_tag_by_mod, mod)
        end

        @doc "Множество wire-type."
        @spec types() :: MapSet.t(String.t())

        def types, do: MapSet.new(@codec_tags)

        @doc "Wire-tag → модуль struct."
        @spec mod_by_tag(String.t()) :: {:ok, module()} | :error

        def mod_by_tag(tag) when is_binary(tag) do
          Map.fetch(@codec_mod_by_tag, tag)
        end

        @doc """
        Wire-type по struct или модулю; `:error`, если тип не объявлен этим плагином.

        Safe-вариант `type/1`: по нему фасад ищет плагин для `dump_tagged/1`, перебирая
        tagged-плагины, — там отсутствие типа не ошибка, а «спрашиваем следующего».
        """
        @spec fetch_type(struct() | module()) :: {:ok, String.t()} | :error

        def fetch_type(%mod{}), do: fetch_type(mod)

        def fetch_type(mod) when is_atom(mod), do: Map.fetch(@codec_tag_by_mod, mod)
      end

      import Core.Helper.Map, only: [field: 2]

      import Core.Codec.Helper,
        only: [
          dump_optional: 2,
          dump_many: 2,
          dump_raw_optional: 3,
          load_optional: 3,
          load_many: 3
        ]

      @after_compile {Core.Codec.Plugin.Opts, :after_compile!}
    end
  end
end
