defmodule Core.Codec.Plugin.Redump do
  @moduledoc """
  Спека пере-дампа (`Core.Codec.Redump`) типов Codec-плагина и генерация `__codec_redump__/1`.

  Тип из `fields:` даёт `{:map, %{wire-ключ => спека}}`:

  | Вид поля | В спеке |
  |---|---|
  | `prim:` с приводимым kind (`Core.Codec.coercible?/1`) | `{:prim, P}` |
  | `prim:` с кастомным kind, `enum:`, `type:` | нет |
  | `prim:` sensitive (и элементом `list:`) | `:sensitive` |
  | `entity: M`, `union: F` | `{:codec, M}` / `{:codec, F}` |
  | `list: спека` | `{:list, спека элемента}`; нет, если у элемента её нет |

  Спека варианта повторяет форму его дампа: тегированный — `{:tagged, %{тег => {:map, поля}}}`,
  без обёртки — `{:map, поля}`; дискриминатор — литерал, переводить в нём нечего. Семейство
  сливает спеки полей вариантов одного тега (форма без обёртки — всех вариантов) в одну map;
  одноимённый ключ с разной спекой — `CompileError` при сборке плагина, а с участием ручного
  варианта — `ArgumentError` при запросе спеки семейства.

  Ручной тип, ручной вариант (спека его полей, `{:map, _}`) и семейство без `variants:` берут спеку
  у колбэка `redump_spec/1`. Тип без клаузы колбэка клаузы `__codec_redump__/1` не получает: он уходит в
  `__codec_redump_missing__/0` (`{тип, тип без клаузы}` — у семейства это его ручной вариант), и
  `ArgumentError` с именами типа и плагина бросает фасад.
  Клауза колбэка на тип с выведенной спекой — `CompileError`.
  """

  alias Core.Codec
  alias Core.Codec.Plugin.Fields
  alias Core.Codec.Plugin.Opts
  alias Core.Codec.Plugin.Variants

  @label "Codec.Plugin"
  @callback_fun {:redump_spec, 1}

  # ===== генерация =====

  @doc false
  defmacro __before_compile__(env) do
    plugin = env.module
    fields = Module.get_attribute(plugin, :codec_fields)
    variants = Module.get_attribute(plugin, :codec_variants)
    union = Module.get_attribute(plugin, :codec_union)
    {unions, manual_unions} = if variants == [], do: {[], List.wrap(union)}, else: {[union], []}
    field_types = Enum.map(fields, &elem(&1, 0))
    derived = field_types ++ for({mod, _address, _place, spec} <- variants, spec != :manual, do: mod)

    manual =
      (Module.get_attribute(plugin, :codec_types) -- (field_types ++ Enum.map(variants, &elem(&1, 0)))) ++ manual_unions

    targets = Opts.manual_targets(plugin, @callback_fun, 0, :module)
    covered = Enum.map(targets, &elem(&1, 1))
    covered? = &(:any in covered or &1 in covered)

    check_derived!(env, targets, derived ++ unions)
    check_merge!(plugin, variants)

    entries =
      Enum.map(fields, &fields_redump/1) ++
        Enum.map(variants, &variant_redump(&1, covered?)) ++
        Enum.map(unions, &family_redump(&1, variants, covered?)) ++
        Enum.map(manual, &manual_redump(&1, covered?))

    missing = for {:missing, type, culprit} <- entries, do: {type, culprit}

    quote do
      @doc false
      @spec __codec_redump_missing__() :: [{module(), module()}]

      def __codec_redump_missing__, do: unquote(missing)

      unquote(redump_ast(for {:spec, type, body} <- entries, do: clause(type, body)))
    end
  end

  # ---

  # Тип без спеки клаузы не получает: клауза, которая только бросает, дала бы функции success typing
  # `none()` против `@spec` и вызову фасада — «will not succeed» у Dialyzer. Отказ бросает фасад.
  defp redump_ast([]), do: nil

  defp redump_ast(clauses) do
    quote do
      @doc false
      @spec __codec_redump__(module()) :: Core.Codec.Redump.spec()

      unquote_splicing(clauses)
    end
  end

  defp check_derived!(env, targets, derived) do
    dead =
      for {line, type} <- targets,
          type in derived,
          do: {@callback_fun, line, type}

    Opts.raise_never_match!(env, dead, "спеку redump этого типа выводит плагин")
  end

  defp check_merge!(plugin, variants) do
    entries = for {mod, _address, place, fields} <- variants, fields != :manual, do: {mod, place, fields_spec(fields)}

    case family(entries) do
      {:ok, _spec} -> :ok
      {:error, conflict} -> raise CompileError, description: "#{@label} #{inspect(plugin)}: #{conflict(conflict)}"
    end
  end

  defp fields_redump({type, fields}), do: {:spec, type, Macro.escape(fields_spec(fields))}

  defp variant_redump({mod, _address, place, :manual}, covered?) do
    if covered?.(mod),
      do:
        {:spec, mod,
         quote(do: Core.Codec.Plugin.Redump.variant_spec(unquote(Macro.escape(place)), redump_spec(unquote(mod))))},
      else: {:missing, mod, mod}
  end

  defp variant_redump({mod, _address, place, fields}, _covered?),
    do: {:spec, mod, Macro.escape(variant_spec(place, fields_spec(fields)))}

  # Семейство с ручным вариантом сливает спеки при исполнении: спеку его полей отдаёт колбэк.
  defp family_redump(union, variants, covered?) do
    manual = for {mod, _address, _place, :manual} <- variants, do: mod

    case {manual, Enum.reject(manual, covered?)} do
      {[], []} ->
        {:ok, spec} = family(for {mod, _address, place, fields} <- variants, do: {mod, place, fields_spec(fields)})

        {:spec, union, Macro.escape(spec)}

      {_manual, [uncovered | _rest]} ->
        {:missing, union, uncovered}

      {_manual, []} ->
        {:spec, union, quote(do: Core.Codec.Plugin.Redump.family!(__MODULE__, unquote(Enum.map(variants, &entry/1))))}
    end
  end

  defp entry({mod, _address, place, :manual}),
    do: quote(do: {unquote(mod), unquote(Macro.escape(place)), redump_spec(unquote(mod))})

  defp entry({mod, _address, place, fields}), do: Macro.escape({mod, place, fields_spec(fields)})

  defp manual_redump(type, covered?) do
    if covered?.(type),
      do: {:spec, type, quote(do: redump_spec(unquote(type)))},
      else: {:missing, type, type}
  end

  defp clause(type, body) do
    quote do
      def __codec_redump__(unquote(type)), do: unquote(body)
    end
  end

  # ===== вывод =====

  @doc false
  @spec fields_spec([Fields.field()]) :: Codec.Redump.spec()

  def fields_spec(fields) do
    specs =
      for {_name, spec, _optional?, wire, _default} <- fields,
          redump = field_spec(spec),
          redump != nil,
          into: %{},
          do: {Fields.wire_key(wire), redump}

    {:map, specs}
  end

  # ---

  defp field_spec({:prim, mod}) do
    cond do
      mod.__domain_sensitive__() -> :sensitive
      Codec.coercible?(mod) -> {:prim, mod}
      true -> nil
    end
  end

  defp field_spec({kind, _mod}) when kind in ~w(enum type)a, do: nil
  defp field_spec({kind, mod}) when kind in ~w(entity union)a, do: {:codec, mod}

  defp field_spec({:list, inner}) do
    case field_spec(inner) do
      nil -> nil
      :sensitive -> :sensitive
      spec -> {:list, spec}
    end
  end

  # ===== спека варианта и семейства =====

  @doc false
  @spec variant_spec(Variants.place(), Codec.Redump.spec()) :: Codec.Redump.spec()

  def variant_spec({:tagged, tag, _disc}, spec), do: {:tagged, %{tag => spec}}
  def variant_spec({:inline, _disc}, spec), do: spec

  @doc false
  @spec family!(module(), [{module(), Variants.place(), Codec.Redump.spec()}]) :: Codec.Redump.spec()

  def family!(plugin, entries) when is_atom(plugin) do
    case family(entries) do
      {:ok, spec} -> spec
      {:error, conflict} -> raise ArgumentError, "#{@label} #{inspect(plugin)}: #{conflict(conflict)}"
    end
  end

  @doc false
  @spec missing!(module(), module()) :: no_return()

  def missing!(type, plugin) when is_atom(type) and is_atom(plugin) do
    raise ArgumentError,
          "#{inspect(type)}: у codec-плагина #{inspect(plugin)} нет спеки redump — " <>
            "тип объявлен вручную, нужна клауза redump_spec/1"
  end

  # ===== общее =====

  defp family([]), do: {:ok, {:map, %{}}}

  defp family([{_mod, {:inline, _disc}, _spec} | _rest] = entries) do
    with {:ok, fields} <- merge(entries, nil), do: {:ok, {:map, fields}}
  end

  defp family(entries) do
    entries
    |> Enum.group_by(fn {_mod, {:tagged, tag, _disc}, _spec} -> tag end)
    |> Enum.reduce_while({:ok, %{}}, fn {tag, members}, {:ok, acc} ->
      case tag_spec(tag, members) do
        {:ok, spec} -> {:cont, {:ok, Map.put(acc, tag, spec)}}
        {:error, conflict} -> {:halt, {:error, conflict}}
      end
    end)
    |> case do
      {:ok, by_tag} -> {:ok, {:tagged, by_tag}}
      {:error, conflict} -> {:error, conflict}
    end
  end

  defp tag_spec(_tag, [{_mod, _place, spec}]), do: {:ok, spec}

  defp tag_spec(tag, members) do
    with {:ok, fields} <- merge(members, tag), do: {:ok, {:map, fields}}
  end

  # Владелец ключа — первый вариант, который его объявил: его и называет конфликт.
  defp merge(entries, tag) do
    entries
    |> Enum.reduce_while({:ok, %{}, %{}}, &merge_entry(&1, &2, tag))
    |> case do
      {:ok, fields, _owners} -> {:ok, fields}
      {:error, conflict} -> {:error, conflict}
    end
  end

  defp merge_entry({mod, _place, {:map, fields}}, {:ok, acc, owners}, tag) do
    case Enum.find(fields, fn {key, spec} -> Map.get(acc, key, spec) != spec end) do
      nil -> {:cont, {:ok, Map.merge(acc, fields), Map.merge(Map.new(fields, fn {key, _} -> {key, mod} end), owners)}}
      {key, _spec} -> {:halt, {:error, {tag, key, [Map.fetch!(owners, key), mod]}}}
    end
  end

  defp conflict({tag, key, mods}) do
    where = if tag, do: "под тегом #{inspect(tag)}", else: "в форме без обёртки"

    "variants: — wire-ключ #{inspect(Atom.to_string(key))} с разной спекой redump у вариантов " <>
      "#{Enum.map_join(mods, ", ", &inspect/1)} #{where}; слитые варианты делят спеку ключа"
  end
end
