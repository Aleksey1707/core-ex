defmodule Core.Codec.Plugin.Variants do
  @moduledoc """
  Варианты семейства Codec-плагина (`use Core.Codec.Plugin, union:, variants:`): проверка адресов и
  генерация `dump/2` / `load/3` вариантов и загрузки по семейству.

  Вариант — `{Mod, адрес, спека}` (поля по спеке, как у `fields:`) или `{Mod, адрес}` (поля пишут
  колбэки `dump_variant/2` / `load_variant/3`). Адрес:

  | Адрес | Wire |
  |---|---|
  | `"tag"` | `%{"type" => "tag", "fields" => поля}` |
  | `{"tag", key: value}` | `%{"type" => "tag", "fields" => поля + %{"key" => value}}` |
  | `[key: value]` | поля + `%{"key" => value}` |

  Дискриминатор пишется как объявлен, сравнивается по строке. Поле struct с его именем в спеку не
  входит: загрузка оставляет значение по умолчанию, которое обязано равняться `value`. Ошибки
  разбора — `ns: :codec`: повреждённая форма — `:invalid_value`, адрес вне семейства или не этого
  варианта — `:unknown_tag` с `detail: %{tag:, discriminator:}`.
  """

  alias Core.Codec.Field
  alias Core.Codec.Plugin.Fields
  alias Core.Error
  alias Core.Helper
  alias Core.Result

  require Error

  @label "Codec.Plugin"
  @tag_key :type
  @fields_key :fields

  @typedoc "Дискриминатор: ключ поля и его значение у варианта."
  @type discriminator :: {atom(), atom() | String.t()}

  @typedoc "Нормализованный адрес: тегированная форма (с дискриминатором или без) либо форма без обёртки."
  @type place :: {:tagged, String.t(), discriminator() | nil} | {:inline, discriminator()}

  @typedoc "Вариант: модуль, адрес как объявлен, нормализованный адрес, поля по спеке или `:manual`."
  @type variant :: {module(), term(), place(), [Field.t()] | :manual}

  @typedoc "Индекс выбора варианта по wire."
  @type index ::
          {:tagged, %{String.t() => module() | {atom(), %{String.t() => module()}}}}
          | {:inline, atom(), %{String.t() => module()}}

  # ===== ключи формы =====

  @doc "Ключ тега тегированной формы."
  @spec tag_key() :: atom()

  def tag_key, do: @tag_key

  @doc "Ключ полей тегированной формы."
  @spec fields_key() :: atom()

  def fields_key, do: @fields_key

  # ===== спека =====

  @doc false
  @spec variants!(module(), term(), module() | nil) :: [variant()]

  def variants!(_plugin, nil, _union), do: []

  def variants!(plugin, _variants, nil) do
    raise CompileError, description: "#{@label} #{inspect(plugin)}: variants: требует union: — модуль-семейство"
  end

  def variants!(plugin, variants, _union) when is_list(variants) and variants != [] do
    parsed = Enum.map(variants, &variant!(plugin, &1))
    Helper.FieldCheck.unique!(Enum.map(parsed, &elem(&1, 0)), "#{@label} #{inspect(plugin)}: variants")
    check_places!(plugin, parsed)

    parsed
  end

  def variants!(plugin, other, _union) do
    raise CompileError,
      description:
        "#{@label} #{inspect(plugin)}: variants: непустой список {Тип, адрес, спека}, задано #{inspect(other)}"
  end

  @doc false
  @spec index([variant()]) :: index()

  def index([{_mod, _address, {:inline, {key, _value}}, _fields} | _rest] = variants) do
    {:inline, key, Map.new(variants, fn {mod, _address, {:inline, {_key, value}}, _fields} -> {string(value), mod} end)}
  end

  def index(variants) do
    by_tag =
      variants
      |> Enum.group_by(fn {_mod, _address, {:tagged, tag, _disc}, _fields} -> tag end)
      |> Map.new(fn {tag, members} -> {tag, tag_entry(members)} end)

    {:tagged, by_tag}
  end

  @doc false
  @spec type_by_mod([variant()]) :: %{module() => String.t()}

  def type_by_mod(variants), do: Map.new(variants, fn {mod, _address, place, _fields} -> {mod, type(place)} end)

  @doc false
  @spec introspection([variant()]) :: [{module(), term(), [Field.t()] | :manual}]

  def introspection(variants), do: Enum.map(variants, fn {mod, address, _place, fields} -> {mod, address, fields} end)

  # ---

  defp variant!(plugin, {mod, address, spec}) when is_atom(mod) and not is_nil(mod) do
    where = "#{@label} #{inspect(plugin)}: variants, вариант #{inspect(mod)}"
    place = place!(address, where)
    disc = disc(place)
    Field.struct_module!(mod, where)
    check_default!(mod, disc, where)

    fields = Field.variant_fields!(mod, spec, List.wrap(disc && elem(disc, 0)), where)
    check_clash!(fields, disc, where)

    {mod, address, place, fields}
  end

  defp variant!(plugin, {mod, address}) when is_atom(mod) and not is_nil(mod) do
    where = "#{@label} #{inspect(plugin)}: variants, вариант #{inspect(mod)}"
    place = place!(address, where)
    Field.struct_module!(mod, where)
    check_default!(mod, disc(place), where)

    {mod, address, place, :manual}
  end

  defp variant!(plugin, other) do
    raise CompileError,
      description:
        "#{@label} #{inspect(plugin)}: variants: ожидается {Тип, адрес, спека} или {Тип, адрес}, " <>
          "задано #{inspect(other)}"
  end

  defp place!(tag, _where) when is_binary(tag) and tag != "", do: {:tagged, tag, nil}

  defp place!({tag, [{key, value}]}, where) when is_binary(tag) and tag != "",
    do: {:tagged, tag, disc!({key, value}, where)}

  defp place!([{key, value}], where), do: {:inline, disc!({key, value}, where)}

  defp place!({tag, disc}, where) when is_binary(tag) and is_list(disc) do
    raise CompileError, description: "#{where}: дискриминатор — одна пара ключ: значение, задано #{inspect(disc)}"
  end

  defp place!(other, where) do
    raise CompileError,
      description: "#{where}: адрес — \"тег\", {\"тег\", ключ: значение} или [ключ: значение], задано #{inspect(other)}"
  end

  defp disc!({key, value} = disc, _where)
       when is_atom(key) and
              ((is_atom(value) and value not in [nil, true, false]) or (is_binary(value) and value != "")),
       do: disc

  defp disc!(other, where) do
    raise CompileError,
      description: "#{where}: дискриминатор — ключ-атом и значение атомом или строкой, задано #{inspect(other)}"
  end

  defp check_default!(_mod, nil, _where), do: :ok

  defp check_default!(mod, {key, value}, where) do
    case Map.fetch(mod.__struct__(), key) do
      {:ok, ^value} ->
        :ok

      :error ->
        :ok

      {:ok, default} ->
        raise CompileError,
          description:
            "#{where}: поле #{inspect(key)} по умолчанию #{inspect(default)}, а дискриминатор — #{inspect(value)}"
    end
  end

  defp check_clash!(_fields, nil, _where), do: :ok

  defp check_clash!(fields, {key, _value}, where) do
    wire = Atom.to_string(key)

    if Enum.any?(fields, &match?(%Field{wire: ^wire}, &1)) do
      raise CompileError, description: "#{where}: wire-ключ #{inspect(wire)} занят дискриминатором"
    end
  end

  defp check_places!(plugin, variants) do
    where = "#{@label} #{inspect(plugin)}: variants"

    forms = Enum.map(variants, &elem(elem(&1, 2), 0))

    case Enum.uniq(forms) do
      [:tagged] ->
        check_tags!(variants, where)

      [:inline] ->
        check_discs!(variants, where)

      _mixed ->
        raise CompileError,
          description: "#{where}: адреса одной формы: тегированная или без обёртки, варианты #{names(variants)}"
    end
  end

  defp check_tags!(variants, where) do
    variants
    |> Enum.group_by(fn {_mod, _address, {:tagged, tag, _disc}, _fields} -> tag end)
    |> Enum.each(fn {tag, members} -> check_shared!(tag, members, where) end)
  end

  defp check_shared!(_tag, [_single], _where), do: :ok

  defp check_shared!(tag, members, where) do
    if Enum.any?(members, &is_nil(disc(elem(&1, 2)))) do
      raise CompileError,
        description:
          "#{where}: тег #{inspect(tag)} общий у #{names(members)} " <>
            "без дискриминатора у каждого"
    end

    check_discs!(members, "#{where}, тег #{inspect(tag)}")
  end

  defp check_discs!(members, where) do
    discs = Enum.map(members, &disc(elem(&1, 2)))

    keys = Enum.map(discs, &elem(&1, 0))

    if length(Enum.uniq(keys)) > 1 do
      raise CompileError, description: "#{where}: разные ключи дискриминатора у #{names(members)}: #{inspect(discs)}"
    end

    values = Enum.map(discs, &string(elem(&1, 1)))

    case values -- Enum.uniq(values) do
      [] ->
        :ok

      dupes ->
        raise CompileError, description: "#{where}: повтор адреса #{inspect(Enum.uniq(dupes))} у #{names(members)}"
    end
  end

  defp names(variants), do: Enum.map_join(variants, ", ", &inspect(elem(&1, 0)))

  defp tag_entry([{mod, _address, {:tagged, _tag, nil}, _fields}]), do: mod

  defp tag_entry([{_mod, _address, {:tagged, _tag, {key, _value}}, _fields} | _rest] = members) do
    {key, Map.new(members, fn {mod, _address, {:tagged, _tag, {_key, value}}, _fields} -> {string(value), mod} end)}
  end

  defp type({:tagged, tag, _disc}), do: tag
  defp type({:inline, {_key, value}}), do: string(value)

  # ===== dump =====

  @doc false
  @spec dump_args(variant()) :: [Macro.t()]

  def dump_args({mod, _address, _place, :manual}),
    do: [quote(generated: true, do: %unquote(mod){} = unquote(value_var())), codec_var()]

  def dump_args({mod, _address, _place, fields}), do: Fields.dump_args(mod, fields)

  @doc false
  @spec dump_guard(variant()) :: Macro.t()

  def dump_guard({_mod, _address, _place, :manual}), do: quote(generated: true, do: is_atom(unquote(codec_var())))
  def dump_guard({_mod, _address, _place, fields}), do: Fields.dump_guard(fields)

  @doc false
  @spec dump_body(variant()) :: Macro.t()

  def dump_body({_mod, _address, place, :manual}) do
    dumped = quote(generated: true, do: dump_variant(unquote(value_var()), unquote(codec_var())))

    wrap(place, with_disc(dumped, disc(place)))
  end

  def dump_body({_mod, _address, place, fields}) do
    pairs = Fields.dump_pairs(fields) ++ disc_pairs(disc(place))

    wrap(place, quote(generated: true, do: %{unquote_splicing(pairs)}))
  end

  # ---

  defp wrap({:tagged, tag, _disc}, fields) do
    pairs = [{Atom.to_string(@tag_key), tag}, {Atom.to_string(@fields_key), fields}]

    quote(generated: true, do: %{unquote_splicing(pairs)})
  end

  defp wrap({:inline, _disc}, fields), do: fields

  defp with_disc(dumped, nil), do: dumped

  defp with_disc(dumped, {key, value}),
    do: quote(generated: true, do: Map.put(unquote(dumped), unquote(Atom.to_string(key)), unquote(value)))

  defp disc_pairs(nil), do: []
  defp disc_pairs({key, value}), do: [{Atom.to_string(key), value}]

  defp value_var, do: Macro.var(:value, __MODULE__)

  # ===== load =====

  @doc false
  @spec load_args(module()) :: [Macro.t()]

  def load_args(mod), do: [mod, wire_var(), codec_var()]

  @doc false
  @spec load_guard() :: Macro.t()

  def load_guard, do: quote(generated: true, do: is_atom(unquote(codec_var())))

  @doc false
  @spec load_body(variant()) :: Macro.t()

  def load_body({mod, _address, place, _fields}) do
    quote generated: true do
      case Core.Codec.Plugin.Variants.address_fields(unquote(wire_var()), unquote(Macro.escape(place)), unquote(mod)) do
        {:ok, fields} -> __codec_variant__(unquote(mod), fields, unquote(codec_var()))
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  @spec family_body(module(), index()) :: Macro.t()

  def family_body(family, index) do
    quote generated: true do
      case Core.Codec.Plugin.Variants.resolve(unquote(wire_var()), unquote(Macro.escape(index)), unquote(family)) do
        {:ok, mod, fields} -> __codec_variant__(mod, fields, unquote(codec_var()))
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  @spec variant_args(variant()) :: [Macro.t()]

  def variant_args({mod, _address, _place, :manual}), do: [mod, wire_var(), codec_var()]
  def variant_args({mod, _address, _place, _fields}), do: Fields.load_args(mod)

  @doc false
  @spec variant_guard(variant()) :: Macro.t()

  def variant_guard({_mod, _address, _place, :manual}),
    do: quote(generated: true, do: is_map(unquote(wire_var())) and is_atom(unquote(codec_var())))

  def variant_guard(_variant), do: Fields.load_guard()

  @doc false
  @spec variant_body(variant()) :: Macro.t()

  def variant_body({mod, _address, _place, :manual}) do
    quote generated: true do
      case load_variant(unquote(mod), unquote(wire_var()), unquote(codec_var())) do
        {:ok, %unquote(mod){} = value} -> {:ok, value}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def variant_body({mod, _address, _place, fields}), do: Fields.load_body(mod, fields)

  @doc false
  @spec resolve(term(), index(), module()) :: {:ok, module(), map()} | {:error, Error.t()}

  def resolve(wire, {:tagged, by_tag}, family) when is_atom(family) do
    with {:ok, tag, fields} <- unwrap(wire, family) do
      case Map.fetch(by_tag, tag) do
        {:ok, mod} when is_atom(mod) -> {:ok, mod, fields}
        {:ok, {key, by_value}} -> pick(fields, key, by_value, tag, family)
        :error -> {:error, unknown(family, tag, nil)}
      end
    end
  end

  def resolve(wire, {:inline, key, by_value}, family) when is_map(wire) and is_atom(family),
    do: pick(wire, key, by_value, nil, family)

  def resolve(_wire, {:inline, _key, _by_value}, family) when is_atom(family), do: {:error, invalid(family)}

  @doc false
  @spec address_fields(term(), place(), module()) :: Result.t(map())

  def address_fields(wire, {:tagged, tag, disc}, mod) when is_atom(mod) do
    with {:ok, wire_tag, fields} <- unwrap(wire, mod) do
      if wire_tag == tag,
        do: check_disc(fields, disc, tag, mod),
        else: {:error, unknown(mod, wire_tag, peek_disc(fields, disc))}
    end
  end

  def address_fields(wire, {:inline, disc}, mod) when is_map(wire) and is_atom(mod),
    do: check_disc(wire, disc, nil, mod)

  def address_fields(_wire, {:inline, _disc}, mod) when is_atom(mod), do: {:error, invalid(mod)}

  # ---

  defp unwrap(wire, module) when is_map(wire) do
    case {Helper.Map.field(wire, @tag_key), Helper.Map.field(wire, @fields_key)} do
      {tag, fields} when is_binary(tag) and is_map(fields) -> {:ok, tag, fields}
      _broken -> {:error, invalid(module)}
    end
  end

  defp unwrap(_wire, module), do: {:error, invalid(module)}

  defp pick(fields, key, by_value, tag, module) do
    with {:ok, value} <- wire_disc(fields, key, module) do
      case Map.fetch(by_value, value) do
        {:ok, mod} -> {:ok, mod, fields}
        :error -> {:error, unknown(module, tag, value)}
      end
    end
  end

  defp peek_disc(_fields, nil), do: nil

  defp peek_disc(fields, {key, _value}) do
    case Helper.Map.field(fields, key) do
      value when is_binary(value) -> value
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      _missing -> nil
    end
  end

  defp check_disc(fields, nil, _tag, _mod), do: {:ok, fields}

  defp check_disc(fields, {key, value}, tag, mod) do
    expected = string(value)

    case wire_disc(fields, key, mod) do
      {:ok, ^expected} -> {:ok, fields}
      {:ok, other} -> {:error, unknown(mod, tag, other)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wire_disc(fields, key, module) do
    case Helper.Map.field(fields, key) do
      value when is_binary(value) -> {:ok, value}
      value when is_atom(value) and not is_nil(value) -> {:ok, Atom.to_string(value)}
      _missing -> {:error, invalid(module)}
    end
  end

  defp wire_var, do: Macro.var(:wire, __MODULE__)

  defp invalid(module) do
    Error.domain(module, code: :invalid_value, ns: :codec, message: "Повреждённая форма варианта")
  end

  defp unknown(module, tag, discriminator) do
    Error.domain(module,
      code: :unknown_tag,
      ns: :codec,
      message: "Неизвестный вариант",
      detail: %{tag: tag, discriminator: discriminator}
    )
  end

  # ===== общее =====

  defp disc({:tagged, _tag, disc}), do: disc
  defp disc({:inline, disc}), do: disc

  defp string(value) when is_binary(value), do: value
  defp string(value) when is_atom(value), do: Atom.to_string(value)

  defp codec_var, do: Macro.var(:codec, __MODULE__)
end
