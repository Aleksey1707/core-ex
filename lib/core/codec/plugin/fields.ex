defmodule Core.Codec.Plugin.Fields do
  @moduledoc """
  Спека полей Codec-плагина (`use Core.Codec.Plugin, fields:`): валидация и генерация
  клауз `dump/2` / `load/3` по ней.

  Поле объявляется keyword-спекой с ровно одним kind-ключом (`prim:`) и необязательными
  `optional: true` и `wire: "ключ"`. Ключи спеки сверяются с полями struct типа (без
  `__struct__` и `events`) — расхождение в любую сторону даёт `CompileError`.

  Значение поля `prim:` — Prim-структура: дамп `codec.dump/1`, загрузка
  `codec.load(Prim, raw)`. Загрузка собирает struct литералом после успешной загрузки
  всех полей; первая ошибка поля — итог, лишние ключи wire игнорируются.
  """

  alias Core.Helper.FieldCheck

  @label "Codec.Plugin"
  @kind_keys ~w(prim)a
  @extra_keys ~w(optional wire)a
  @skipped_keys ~w(__struct__ events)a

  @typedoc "Нормализованная спека значения поля."
  @type spec :: {:prim, module()}

  @typedoc "Нормализованное поле: имя, спека значения, признак необязательности, wire-ключ."
  @type field :: {atom(), spec(), boolean(), String.t()}

  # ===== спека =====

  @doc false
  @spec fields!(module(), term(), [module()]) :: [{module(), [field()]}]

  def fields!(_plugin, nil, _types), do: []

  def fields!(plugin, fields, types) when is_list(fields) do
    pairs = Enum.map(fields, &pair!(plugin, &1))
    check_types!(plugin, Enum.map(pairs, &elem(&1, 0)), types)

    Enum.map(pairs, fn {type, spec} -> {type, type_fields!(plugin, type, spec)} end)
  end

  def fields!(plugin, other, _types) do
    raise CompileError,
      description: "#{@label} #{inspect(plugin)}: fields: — список пар {Тип, спека}, задано #{inspect(other)}"
  end

  # ---

  defp pair!(_plugin, {type, spec}) when is_atom(type) and not is_nil(type), do: {type, spec}

  defp pair!(plugin, other) do
    raise CompileError,
      description: "#{@label} #{inspect(plugin)}: fields: — ожидается пара {Тип, спека}, задано #{inspect(other)}"
  end

  defp check_types!(plugin, keys, types) do
    check_unique!(keys, "#{@label} #{inspect(plugin)}: fields: — типы объявлены дважды")

    case keys -- types do
      [] ->
        :ok

      foreign ->
        raise CompileError,
          description: "#{@label} #{inspect(plugin)}: fields: — типы вне types:: #{inspect(foreign)}"
    end
  end

  defp type_fields!(plugin, type, spec) do
    where = "#{@label} #{inspect(plugin)}: fields:, тип #{inspect(type)}"

    if not Keyword.keyword?(spec) or spec == [] do
      raise CompileError, description: "#{where} — непустой keyword-список полей"
    end

    check_unique!(Keyword.keys(spec), "#{where}: поля повторяются")
    fields = Enum.map(spec, fn {name, opts} -> field!(name, opts, "#{where}, поле #{name}") end)
    check_struct!(type, Keyword.keys(spec), where)
    check_unique!(Enum.map(fields, &elem(&1, 3)), "#{where}: wire-ключи повторяются")

    fields
  end

  defp field!(name, opts, where) do
    if not Keyword.keyword?(opts) do
      raise CompileError, description: "#{where} — keyword-спека"
    end

    case Keyword.keys(opts) -- (@kind_keys ++ @extra_keys) do
      [] -> :ok
      unknown -> raise CompileError, description: "#{where}: неизвестные ключи #{inspect(unknown)}"
    end

    {name, spec!(opts, where), optional!(opts, where), wire!(name, opts, where)}
  end

  defp spec!(opts, where) do
    case Keyword.take(opts, @kind_keys) do
      [prim: mod] ->
        FieldCheck.prim!(mod, where)
        {:prim, mod}

      other ->
        raise CompileError, description: "#{where}: нужен ровно один из prim:, задано #{inspect(other)}"
    end
  end

  defp optional!(opts, where) do
    case Keyword.get(opts, :optional, false) do
      optional? when is_boolean(optional?) -> optional?
      other -> raise CompileError, description: "#{where}: optional: — boolean, задано #{inspect(other)}"
    end
  end

  defp wire!(name, opts, where) do
    case Keyword.fetch(opts, :wire) do
      :error -> Atom.to_string(name)
      {:ok, wire} when is_binary(wire) and wire != "" -> wire
      {:ok, other} -> raise CompileError, description: "#{where}: wire: — непустая строка, задано #{inspect(other)}"
    end
  end

  defp check_struct!(type, names, where) do
    FieldCheck.module!(type, where)

    if not function_exported?(type, :__struct__, 0) do
      raise CompileError, description: "#{where}: #{inspect(type)} не struct"
    end

    struct_keys = Map.keys(type.__struct__()) -- @skipped_keys

    case {struct_keys -- names, names -- struct_keys} do
      {[], []} ->
        :ok

      {missing, extra} ->
        raise CompileError,
          description:
            "#{where}: спека расходится со struct — поля struct без спеки #{inspect(Enum.sort(missing))}, " <>
              "поля спеки без struct #{inspect(Enum.sort(extra))}"
    end
  end

  defp check_unique!(items, message) do
    case items -- Enum.uniq(items) do
      [] -> :ok
      dupes -> raise CompileError, description: "#{message}: #{inspect(Enum.uniq(dupes))}"
    end
  end

  # ===== dump =====

  @doc false
  @spec dump_args(module(), [field()]) :: [Macro.t()]

  def dump_args(type, fields) do
    pairs = Enum.map(fields, &dump_pattern/1)

    [quote(generated: true, do: %unquote(type){unquote_splicing(pairs)}), codec_var()]
  end

  @doc false
  @spec dump_guard([field()]) :: Macro.t()

  def dump_guard(fields) do
    fields
    |> Enum.filter(fn {_name, _spec, optional?, _wire} -> optional? end)
    |> Enum.map(&optional_guard/1)
    |> Enum.reduce(quote(generated: true, do: is_atom(unquote(codec_var()))), fn guard, acc ->
      quote(generated: true, do: unquote(acc) and unquote(guard))
    end)
  end

  @doc false
  @spec dump_body([field()]) :: Macro.t()

  def dump_body(fields) do
    pairs = Enum.map(fields, fn {name, _spec, optional?, wire} -> {wire, dump_value(var(name), optional?)} end)

    quote(generated: true, do: %{unquote_splicing(pairs)})
  end

  # ---

  defp dump_pattern({name, {:prim, mod}, false, _wire}),
    do: {name, quote(generated: true, do: %unquote(mod){} = unquote(var(name)))}

  defp dump_pattern({name, _spec, true, _wire}), do: {name, var(name)}

  defp optional_guard({name, {:prim, mod}, true, _wire}) do
    quote(generated: true, do: is_nil(unquote(var(name))) or is_struct(unquote(var(name)), unquote(mod)))
  end

  defp dump_value(value, false), do: quote(generated: true, do: unquote(codec_var()).dump(unquote(value)))

  defp dump_value(value, true) do
    quote generated: true do
      if is_nil(unquote(value)), do: nil, else: unquote(codec_var()).dump(unquote(value))
    end
  end

  # ===== load =====

  @doc false
  @spec load_args(module()) :: [Macro.t()]

  def load_args(type), do: [type, wire_var(), codec_var()]

  @doc false
  @spec load_guard() :: Macro.t()

  def load_guard, do: quote(generated: true, do: is_map(unquote(wire_var())) and is_atom(unquote(codec_var())))

  @doc false
  @spec load_body(module(), [field()]) :: Macro.t()

  def load_body(type, fields) do
    steps = Enum.map(fields, &load_step/1)
    pairs = Enum.map(fields, fn {name, _spec, _optional?, _wire} -> {name, var(name)} end)

    ok = quote(generated: true, do: {:ok, %unquote(type){unquote_splicing(pairs)}})
    error = quote(generated: true, do: ({:error, reason} -> {:error, reason}))

    {:with, [generated: true], steps ++ [[do: ok, else: error]]}
  end

  # ---

  defp load_step({name, {:prim, mod}, optional?, wire}) do
    raw = quote(generated: true, do: Core.Helper.Map.field(unquote(wire_var()), unquote(wire_key(wire))))

    call =
      if optional?,
        do:
          quote(generated: true, do: Core.Codec.Helper.load_optional(unquote(mod), unquote(raw), unquote(codec_var()))),
        else: quote(generated: true, do: unquote(codec_var()).load(unquote(mod), unquote(raw)))

    quote(generated: true, do: {:ok, unquote(var(name))} <- unquote(call))
  end

  # `field/2` читает и атомарный, и строковый ключ, но принимает атом: wire-ключ — литерал
  # спеки в коде плагина, а не внешние данные, и таблицу атомов не засоряет.
  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp wire_key(wire), do: String.to_atom(wire)

  defp wire_var, do: Macro.var(:wire, __MODULE__)

  # ===== общее =====

  # Поля — в своём контексте: поле с именем `codec` или `wire` не перекрывает аргумент функции.
  defp var(name), do: Macro.var(name, Core.Codec.Plugin.Fields.Value)

  defp codec_var, do: Macro.var(:codec, __MODULE__)
end
