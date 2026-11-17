defmodule Core.Codec.Plugin.Variants do
  @moduledoc """
  Варианты семейства Codec-плагина (`use Core.Codec.Plugin, union:`): состав из реестра семейства
  (`use Core.Union`) и генерация `dump/2` / `load/3` вариантов и загрузки по семейству.

  Семейство объявляет состав и адреса в своём модуле; плагин берёт их из `__core_variants__/0`.
  Поля декларативного варианта — из его `__core_fields__/0`, вариант-Prim грузится и дампится своим
  кодеком, ручной вариант — колбэками `dump_variant/2` / `load_variant/3`. Адрес:

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

  alias Core.Codec.Plugin.Fields
  alias Core.Error
  alias Core.Helper
  alias Core.Prim
  alias Core.Result

  require Error

  @where "Codec.Plugin: variants"
  @tag_key :type
  @fields_key :fields

  @typedoc "Дискриминатор: ключ поля и его значение у варианта."
  @type discriminator :: {atom(), atom() | String.t()}

  @typedoc "Нормализованный адрес: тегированная форма (с дискриминатором или без) либо форма без обёртки."
  @type place :: {:tagged, String.t(), discriminator() | nil} | {:inline, discriminator()}

  @typedoc """
  Источник полей варианта: IR декларативной структуры (`:domain`), значение Prim (`:prim`, wire —
  дамп Prim) или ручные колбэки (`:manual`).
  """
  @type source :: {:domain, [map()]} | :prim | :manual

  @typedoc "Вариант: модуль, адрес как объявлен, нормализованный адрес и источник полей."
  @type variant :: {module(), term(), place(), source()}

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
  @spec union_variants(module() | nil) :: [variant()]

  def union_variants(nil), do: []

  def union_variants(family) when is_atom(family) do
    if Helper.Module.exports?(family, :__core_variants__, 0),
      do: Enum.map(family.__core_variants__(), &union_variant!/1),
      else: []
  end

  @doc false
  @spec address!(term(), String.t()) :: place()

  def address!(tag, _where) when is_binary(tag) and tag != "", do: {:tagged, tag, nil}

  def address!({tag, [{key, value}]}, where) when is_binary(tag) and tag != "",
    do: {:tagged, tag, disc!({key, value}, where)}

  def address!([{key, value}], where), do: {:inline, disc!({key, value}, where)}

  def address!({tag, disc}, where) when is_binary(tag) and is_list(disc) do
    Helper.Opts.reject!(where, "дискриминатор: ожидается одна пара ключ: значение, получено #{inspect(disc)}")
  end

  def address!(other, where) do
    Helper.Opts.reject!(
      where,
      "адрес: ожидается \"тег\", {\"тег\", ключ: значение} или [ключ: значение], получено #{inspect(other)}"
    )
  end

  @doc false
  @spec check_places!([{module(), place()}], String.t()) :: :ok

  def check_places!(variants, where \\ @where) when is_list(variants) and is_binary(where) do
    forms = Enum.map(variants, fn {_mod, place} -> elem(place, 0) end)

    case Enum.uniq(forms) do
      [:tagged] ->
        check_tags!(variants, where)

      [:inline] ->
        check_discs!(variants, where)

      _mixed ->
        Helper.Opts.reject!(where, "адреса одной формы: тегированная или без обёртки, варианты #{names(variants)}")
    end
  end

  @doc false
  @spec check_default!(module(), discriminator() | nil, String.t()) :: :ok

  def check_default!(_mod, nil, _where), do: :ok

  def check_default!(mod, {key, value}, where) do
    case Map.fetch(mod.__struct__(), key) do
      {:ok, ^value} ->
        :ok

      :error ->
        :ok

      {:ok, default} ->
        Helper.Opts.reject!(
          where,
          "поле #{inspect(key)} по умолчанию #{inspect(default)}, а дискриминатор — #{inspect(value)}"
        )
    end
  end

  @doc false
  @spec check_wire_clash!([String.t()], discriminator() | nil, String.t()) :: :ok

  def check_wire_clash!(_wires, nil, _where), do: :ok

  def check_wire_clash!(wires, {key, _value}, where) when is_list(wires) do
    wire = Atom.to_string(key)

    if wire in wires do
      Helper.Opts.reject!(where, "wire-ключ #{inspect(wire)} занят дискриминатором")
    end

    :ok
  end

  @doc false
  @spec index([variant()]) :: index()

  def index([{_mod, _address, {:inline, {key, _value}}, _source} | _rest] = variants) do
    {:inline, key, Map.new(variants, fn {mod, _address, {:inline, {_key, value}}, _source} -> {string(value), mod} end)}
  end

  def index(variants) do
    by_tag =
      variants
      |> Enum.group_by(fn {_mod, _address, {:tagged, tag, _disc}, _source} -> tag end)
      |> Map.new(fn {tag, members} -> {tag, tag_entry(members)} end)

    {:tagged, by_tag}
  end

  @doc false
  @spec type_by_mod([variant()]) :: %{module() => String.t()}

  def type_by_mod(variants), do: Map.new(variants, fn {mod, _address, place, _source} -> {mod, place_type(place)} end)

  @doc false
  @spec place_type(place()) :: String.t()

  def place_type({:tagged, tag, _disc}), do: tag
  def place_type({:inline, {_key, value}}), do: string(value)

  # ---

  defp union_variant!(%{module: mod, address: address, place: place, kind: kind}) do
    where = "#{@where}: #{inspect(mod)}"

    source =
      case kind do
        :prim -> :prim
        :manual -> :manual
        :domain -> {:domain, domain_fields!(mod, place, where)}
      end

    {mod, address, place, source}
  end

  # Поле-дискриминатор в поля варианта не входит: его значение при загрузке оставляет defstruct, а
  # при дампе пишет адрес (`Core.Union`).
  defp domain_fields!(mod, place, where) do
    fields =
      if Helper.Module.exports?(mod, :__core_fields__, 0),
        do: mod.__core_fields__(),
        else: Helper.Opts.reject!(where, "#{inspect(mod)} не декларативная структура: нет __core_fields__/0")

    case disc(place) do
      nil -> fields
      {key, _value} -> Enum.reject(fields, &(&1.name == key))
    end
  end

  defp disc!({key, value} = disc, _where)
       when is_atom(key) and
              ((is_atom(value) and value not in [nil, true, false]) or (is_binary(value) and value != "")),
       do: disc

  defp disc!(other, where) do
    Helper.Opts.reject!(
      where,
      "дискриминатор: ожидается ключ-атом и значение атомом или строкой, получено #{inspect(other)}"
    )
  end

  defp check_tags!(variants, where) do
    variants
    |> Enum.group_by(fn {_mod, {:tagged, tag, _disc}} -> tag end)
    |> Enum.each(fn {tag, members} -> check_shared!(tag, members, where) end)
  end

  defp check_shared!(_tag, [_single], _where), do: :ok

  defp check_shared!(tag, members, where) do
    if Enum.any?(members, &is_nil(disc(elem(&1, 1)))) do
      Helper.Opts.reject!(where, "тег #{inspect(tag)} общий у #{names(members)} без дискриминатора у каждого")
    end

    check_discs!(members, "#{where}: #{inspect(tag)}")
  end

  defp check_discs!(members, where) do
    discs = Enum.map(members, &disc(elem(&1, 1)))

    keys = Enum.map(discs, &elem(&1, 0))

    if length(Enum.uniq(keys)) > 1 do
      Helper.Opts.reject!(where, "разные ключи дискриминатора у #{names(members)}: #{inspect(discs)}")
    end

    values = Enum.map(discs, &string(elem(&1, 1)))

    case values -- Enum.uniq(values) do
      [] ->
        :ok

      dupes ->
        Helper.Opts.reject!(where, "повтор адреса #{inspect(Enum.uniq(dupes))} у #{names(members)}")
    end
  end

  defp names(variants), do: Enum.map_join(variants, ", ", &inspect(elem(&1, 0)))

  defp tag_entry([{mod, _address, {:tagged, _tag, nil}, _source}]), do: mod

  defp tag_entry([{_mod, _address, {:tagged, _tag, {key, _value}}, _source} | _rest] = members) do
    {key, Map.new(members, fn {mod, _address, {:tagged, _tag, {_key, value}}, _source} -> {string(value), mod} end)}
  end

  # ===== dump =====

  @doc false
  @spec dump_args(variant()) :: [Macro.t()]

  def dump_args({mod, _address, _place, :manual}),
    do: [quote(generated: true, do: %unquote(mod){} = unquote(value_var())), codec_var()]

  def dump_args({mod, _address, _place, :prim}),
    do: [quote(generated: true, do: %unquote(mod){} = unquote(value_var())), codec_var()]

  def dump_args({mod, _address, _place, {:domain, fields}}), do: Fields.dump_args_ir(mod, fields)

  @doc false
  @spec dump_guard(variant()) :: Macro.t()

  def dump_guard({_mod, _address, _place, :manual}), do: quote(generated: true, do: is_atom(unquote(codec_var())))
  def dump_guard({_mod, _address, _place, :prim}), do: quote(generated: true, do: is_atom(unquote(codec_var())))
  def dump_guard({_mod, _address, _place, {:domain, fields}}), do: Fields.dump_guard_ir(fields)

  @doc false
  @spec dump_body(variant()) :: Macro.t()

  def dump_body({_mod, _address, place, :manual}) do
    dumped = quote(generated: true, do: dump_variant(unquote(value_var()), unquote(codec_var())))

    wrap(place, with_disc(dumped, disc(place)))
  end

  # Wire Prim-варианта — его дамп: поля варианта писать некуда, обёртка адреса остаётся одна.
  # Дамп идёт через Prim-профиль фасада: клоуза `dump/1` этого же варианта ушла бы в рекурсию.
  def dump_body({_mod, _address, place, :prim}) do
    dumped = quote(generated: true, do: unquote(codec_var()).__codec_prim__().dump(unquote(value_var())))

    wrap(place, dumped)
  end

  def dump_body({_mod, _address, place, {:domain, fields}}) do
    pairs = Fields.dump_pairs_ir(fields) ++ disc_pairs(disc(place))

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
  def variant_args({mod, _address, _place, :prim}), do: [mod, wire_var(), codec_var()]
  def variant_args({mod, _address, _place, {:domain, _fields}}), do: Fields.load_args(mod)

  @doc false
  @spec variant_guard(variant()) :: Macro.t()

  def variant_guard({_mod, _address, _place, :manual}),
    do: quote(generated: true, do: is_map(unquote(wire_var())) and is_atom(unquote(codec_var())))

  def variant_guard({_mod, _address, _place, :prim}), do: quote(generated: true, do: is_atom(unquote(codec_var())))
  def variant_guard({_mod, _address, _place, {:domain, _fields}}), do: Fields.load_guard()

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

  # Поля варианта-Prim — его wire-значение целиком: дамп пишет его в `fields`, загрузка отдаёт
  # кодеку Prim как есть.
  def variant_body({mod, _address, _place, :prim}) do
    quote generated: true do
      case unquote(codec_var()).__codec_prim__().load(unquote(mod), unquote(wire_var())) do
        {:ok, %unquote(mod){} = value} -> {:ok, value}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def variant_body({mod, _address, _place, {:domain, fields}}), do: Fields.load_body_ir(mod, fields)

  @doc false
  @spec resolve(term(), index(), module()) :: {:ok, module(), term()} | {:error, Error.t()}

  def resolve(wire, {:tagged, by_tag}, family) when is_atom(family) do
    with {:ok, tag, fields} <- unwrap(wire, family) do
      case Map.fetch(by_tag, tag) do
        {:ok, mod} when is_atom(mod) -> resolve_target(mod, fields, family)
        {:ok, {key, by_value}} -> pick(fields, key, by_value, tag, family)
        :error -> {:error, unknown(family, tag, nil)}
      end
    end
  end

  def resolve(wire, {:inline, key, by_value}, family) when is_map(wire) and is_atom(family),
    do: pick(wire, key, by_value, nil, family)

  def resolve(_wire, {:inline, _key, _by_value}, family) when is_atom(family), do: {:error, invalid(family)}

  @doc false
  @spec address_fields(term(), place(), module()) :: Result.t()

  def address_fields(wire, place, mod) when is_atom(mod) do
    if Prim.prim?(mod),
      do: prim_address_fields(wire, place, mod),
      else: struct_address_fields(wire, place, mod)
  end

  # ---

  defp struct_address_fields(wire, {:tagged, tag, disc}, mod) do
    with {:ok, wire_tag, fields} <- unwrap(wire, mod) do
      if wire_tag == tag,
        do: check_disc(fields, disc, tag, mod),
        else: {:error, unknown(mod, wire_tag, peek_disc(fields, disc))}
    end
  end

  defp struct_address_fields(wire, {:inline, disc}, mod) when is_map(wire),
    do: check_disc(wire, disc, nil, mod)

  defp struct_address_fields(_wire, {:inline, _disc}, mod), do: {:error, invalid(mod)}

  defp prim_address_fields(wire, {:tagged, tag, _disc}, mod) when is_map(wire) do
    case Helper.Map.field(wire, @tag_key) do
      ^tag -> prim_value(wire, mod)
      wire_tag when is_binary(wire_tag) -> {:error, unknown(mod, wire_tag, nil)}
      _broken -> {:error, invalid(mod)}
    end
  end

  defp prim_address_fields(_wire, _place, mod), do: {:error, invalid(mod)}

  defp prim_value(wire, mod) do
    case Helper.Map.key(wire, @fields_key) do
      {:ok, key} -> {:ok, Map.fetch!(wire, key)}
      :error -> {:error, invalid(mod)}
    end
  end

  defp unwrap(wire, module) when is_map(wire) do
    case {Helper.Map.field(wire, @tag_key), Helper.Map.key(wire, @fields_key)} do
      {tag, {:ok, key}} when is_binary(tag) -> {:ok, tag, Map.fetch!(wire, key)}
      _broken -> {:error, invalid(module)}
    end
  end

  defp unwrap(_wire, module), do: {:error, invalid(module)}

  defp resolve_target(mod, fields, _family) when is_map(fields), do: {:ok, mod, fields}

  defp resolve_target(mod, fields, family) do
    if Prim.prim?(mod), do: {:ok, mod, fields}, else: {:error, invalid(family)}
  end

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
