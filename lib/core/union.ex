defmodule Core.Union do
  @moduledoc """
  Семейство вариантов: состав семейства и адреса вариантов объявляются в его модуле.

      defmodule Shape do
        use Core.Union,
          variants: [
            {Shape.Circle, "circle"},
            {Shape.Rect, {"polygon", kind: :rect}},
            {Shape.Blob, [kind: :blob]}
          ]
      end

  Вариант — `{Модуль, адрес}`; полей варианта объявление не знает: у декларативной структуры
  (`use Core.Struct`) поля берутся из её `__core_fields__/0`, у Prim — это значение Prim, у типа с
  ручным Codec — колбэки `dump_variant/2` / `load_variant/3` Codec-плагина. Поэтому вариантом может
  быть Prim (получатель телефон/email), декларативная структура и любой struct с ручным кодеком.

  Адрес — одна из трёх форм, одна на семейство:

  | Адрес | Wire |
  |---|---|
  | `"tag"` | `%{"type" => "tag", "fields" => поля}` |
  | `{"tag", key: value}` | тегированная форма, `"key" => value` внутри `fields` |
  | `[key: value]` | поля и `"key" => value` без обёртки |

  Дискриминатор — одна пара `key: value`; поле struct с его именем в поля варианта не входит, у
  загрузки остаётся значение по умолчанию, и оно MUST равняться `value`. Вариант-Prim объявляется
  только тегом: `"fields"` — дамп Prim, наложить на него дискриминатор нечем.

  Обслуживает семейство Codec-плагин: `use Core.Codec.Plugin, union: Shape` берёт состав из
  `__core_variants__/0` и генерирует `dump/2` / `load/3` каждого варианта и загрузку семейства по
  адресу. Правило адреса одно на объявление и на плагин — `Core.Codec.Plugin.Variants`.

  Вариант-Prim занимает свой модуль в фасаде, как любой тип плагина: дамп и загрузка этого Prim
  идут формой адреса, поэтому тот же Prim не объявляется ещё и полем `prim:` в том же фасаде.

  Порождается:

  - `__core_variants__/0` — внутренняя: варианты единым списком `Core.Union.Variant`, форма не
    контракт; её читает `Core.Union.variants/1`;
  - `types/0` — множество wire-тегов (у формы без обёртки — значений дискриминатора);
  - `variant/1` — вариант по struct или модулю: `{:ok, %Core.Union.Variant{}} | :error`.

  `CompileError` с префиксом `Union: variants: …`: повтор адреса, общий тег у вариантов без
  дискриминатора у каждого, две формы адреса в семействе, разные ключи дискриминатора, wire-ключ
  дискриминатора занят полем, значение поля-дискриминатора по умолчанию не равно адресу, вариант не
  struct, вариант-Prim не в тегированной форме.
  """

  alias Core.Codec.Plugin.Variants
  alias Core.Field.Spec
  alias Core.Helper
  alias Core.Prim
  alias Core.Union.Variant

  @label "Union"
  @required_keys ~w(variants)a
  @optional_keys ~w()a
  @expression_keys ~w(variants)a
  @where "Union: variants"

  @doc "Объявить семейство вариантов (`variants:`)."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)
    variants = Keyword.fetch!(opts, :variants)

    quote do
      @core_variants Core.Union.variants!(unquote(variants))
      @core_variant_index Map.new(@core_variants, &{&1.module, &1})

      @doc false
      @spec __core_variants__() :: [Core.Union.Variant.t()]

      def __core_variants__, do: @core_variants

      @doc "Множество wire-тегов семейства; у формы без обёртки — значений дискриминатора."
      @spec types() :: MapSet.t(String.t())

      def types, do: Core.Union.types(@core_variants)

      @doc "Вариант по struct или модулю."
      @spec variant(struct() | module()) :: {:ok, Core.Union.Variant.t()} | :error

      def variant(%module{}), do: variant(module)

      def variant(module) when is_atom(module), do: Map.fetch(@core_variant_index, module)
    end
  end

  @doc "Варианты семейства в порядке объявления; пустой список — модуль не объявлен через `use Core.Union`."
  @spec variants(module()) :: [Variant.t()]

  def variants(family) when is_atom(family) do
    if Helper.Module.exports?(family, :__core_variants__, 0), do: family.__core_variants__(), else: []
  end

  @doc "Множество wire-тегов семейства по его вариантам."
  @spec types([Variant.t()]) :: MapSet.t(String.t())

  def types(variants) when is_list(variants) do
    MapSet.new(variants, fn %Variant{place: place} -> Variants.place_type(place) end)
  end

  @doc false
  @spec variants!(term()) :: [Variant.t()]

  def variants!(variants) when is_list(variants) and variants != [] do
    parsed = Enum.map(variants, &variant!/1)
    Helper.FieldCheck.unique!(Enum.map(parsed, & &1.module), @where)
    Variants.check_places!(Enum.map(parsed, &{&1.module, &1.place}), @where)

    parsed
  end

  def variants!(other),
    do: Helper.Opts.reject!(@where, "ожидается непустой список {Тип, адрес}, получено #{inspect(other)}")

  # ---

  defp variant!({mod, address}) when is_atom(mod) and not is_nil(mod) do
    where = "#{@where}: #{inspect(mod)}"
    place = Variants.address!(address, where)
    Spec.struct_module!(mod, where)
    disc = disc(place)

    Variants.check_default!(mod, disc, where)

    kind = kind(mod)
    check_prim_place!(kind, place, where)
    check_clash!(mod, kind, disc, where)

    %Variant{module: mod, address: address, place: place, kind: kind}
  end

  defp variant!(other),
    do: Helper.Opts.reject!(@where, "ожидается {Тип, адрес}, получено #{inspect(other)}")

  defp kind(mod) do
    cond do
      Prim.prim?(mod) -> :prim
      Helper.Module.exports?(mod, :__core_fields__, 0) -> :domain
      true -> :manual
    end
  end

  defp disc({:tagged, _tag, disc}), do: disc
  defp disc({:inline, disc}), do: disc

  # Wire Prim-варианта — сам дамп Prim: обёртка адреса остаётся единственным местом, куда лёг бы
  # дискриминатор, поэтому такая форма отвергается при объявлении.
  defp check_prim_place!(:prim, {:tagged, _tag, nil}, _where), do: :ok

  defp check_prim_place!(:prim, _place, where),
    do: Helper.Opts.reject!(where, "Prim-вариант — только тегированная форма: wire обёртки — дамп Prim")

  defp check_prim_place!(_kind, _place, _where), do: :ok

  defp check_clash!(_mod, :prim, _disc, _where), do: :ok

  defp check_clash!(mod, kind, disc, where), do: Variants.check_wire_clash!(wire_keys(mod, kind, disc), disc, where)

  # Поле-дискриминатор — само собой место его wire-ключа: проверяется, что ключ не занят другим полем.
  defp wire_keys(mod, :domain, disc), do: Enum.map(drop_disc(mod.__core_fields__(), disc), & &1.wire)

  # У ручного варианта декларации полей нет: ключи его wire знает только его плагин.
  defp wire_keys(_mod, :manual, _disc), do: []

  defp drop_disc(fields, {key, _value}), do: Enum.reject(fields, &(&1.name == key))
  defp drop_disc(fields, nil), do: fields
end
