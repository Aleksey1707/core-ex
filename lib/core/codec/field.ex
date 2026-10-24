defmodule Core.Codec.Field do
  @moduledoc """
  Поле спеки полей и её грамматика: нормализатор keyword-спеки и его проверки.

  Спеку говорят Codec-плагин по полям (`use Core.Codec.Plugin, fields:`), варианты семейства,
  нагрузка события (`Core.Es.Event.Payload`), `Core.Es.ValueChanged` и подписи
  (`Core.Labels.Fields`). Поле объявляется keyword-спекой с ровно одним kind-ключом
  (`prim:` / `enum:` / `entity:` / `union:` / `list:` / `type:`) и необязательными `optional: true`
  и `wire: "ключ"`; режимные ключи — `default:` у плагина, `subject:` у нагрузки (ADR-0056, ADR-0073).

  Модуль внутренний для библиотеки.
  """

  alias Core.Helper.FieldCheck
  alias Core.Prim

  @label "Codec.Plugin"
  @kind_keys ~w(prim enum entity union list type)a
  @extra_keys ~w(optional wire default)a
  @skipped_keys ~w(__struct__ events)a
  @type_values FieldCheck.type_values()

  @enforce_keys ~w(name spec optional? wire default subject)a
  defstruct @enforce_keys

  @typedoc "Нормализованная спека значения поля."
  @type spec ::
          {:prim, module()}
          | {:enum, module()}
          | {:entity, module()}
          | {:union, module()}
          | {:list, spec()}
          | {:type, atom()}

  @typedoc "Значение `default:`: нет или wire-литерал."
  @type default :: :none | {:default, term()}

  @typedoc """
  Субъект ПДн-поля нагрузки события (`subject:`): `:aggregate_id` или имя поля той же нагрузки;
  `nil` — поле без `subject:`. У плагина всегда `nil`.
  """
  @type subject :: atom() | nil

  @typedoc """
  Режим нормализации: `:plugin` — плагин с загрузкой (`default:` разрешён), `:dump_only` — плагин
  при `loadable: false`, `:payload` — нагрузка события (`subject:` разрешён, `default:` и wire-ключ на
  `$` — нет), `:labels` — подписи.
  """
  @type mode :: :plugin | :dump_only | :payload | :labels

  @typedoc "Нормализованное поле: имя, спека значения, необязательность, wire-ключ, `default:`, субъект."
  @type t :: %__MODULE__{
          name: atom(),
          spec: spec(),
          optional?: boolean(),
          wire: String.t(),
          default: default(),
          subject: subject()
        }

  # ===== спека =====

  @doc false
  @spec fields!(module(), term(), boolean()) :: [{module(), [t()]}]

  def fields!(_plugin, nil, _loadable?), do: []

  def fields!(plugin, fields, loadable?) when is_list(fields) do
    pairs = Enum.map(fields, &pair!(plugin, &1))
    FieldCheck.unique!(Enum.map(pairs, &elem(&1, 0)), "#{@label} #{inspect(plugin)}: fields")
    mode = if loadable?, do: :plugin, else: :dump_only

    Enum.map(pairs, fn {type, spec} ->
      {type, type_fields!(type, spec, [], mode, "#{@label} #{inspect(plugin)}: fields, тип #{inspect(type)}")}
    end)
  end

  def fields!(plugin, other, _loadable?) do
    raise CompileError,
      description: "#{@label} #{inspect(plugin)}: fields: список пар {Тип, спека}, задано #{inspect(other)}"
  end

  @doc false
  @spec normalize!(term(), mode(), String.t()) :: [t()]

  def normalize!(spec, :payload, where) when is_binary(where) do
    case defaults(spec) do
      [] ->
        spec
        |> spec_fields!(:payload, where)
        |> check_payload_wires!(where)

      names ->
        raise CompileError,
          description:
            "#{where}: default: у нагрузки события нет (поля #{inspect(names)}): " <>
              "развитие события — новый тег и апкаст"
    end
  end

  def normalize!(spec, mode, where) when mode in ~w(plugin dump_only labels)a and is_binary(where),
    do: spec_fields!(spec, mode, where)

  @doc false
  @spec variant_fields!(module(), term(), [atom()], String.t()) :: [t()]

  def variant_fields!(type, spec, skipped, where) when is_atom(type) and is_list(skipped),
    do: type_fields!(type, spec, skipped, :plugin, where)

  @doc false
  @spec struct_module!(module(), String.t()) :: :ok

  def struct_module!(mod, where) do
    FieldCheck.module!(mod, where)

    if not Core.Helper.Module.exports?(mod, :__struct__, 0) do
      raise CompileError, description: "#{where}: #{inspect(mod)} не struct"
    end

    :ok
  end

  @doc false
  @spec value_spec(module(), String.t()) :: spec()

  def value_spec(mod, where) when is_atom(mod) do
    FieldCheck.module!(mod, where)

    cond do
      Prim.prim?(mod) -> {:prim, mod}
      Core.Enum.enum?(mod) -> {:enum, mod}
      true -> kind_spec!(:entity, mod, where)
    end
  end

  # ---

  defp pair!(_plugin, {type, spec}) when is_atom(type) and not is_nil(type), do: {type, spec}

  defp pair!(plugin, other) do
    raise CompileError,
      description: "#{@label} #{inspect(plugin)}: fields: ожидается пара {Тип, спека}, задано #{inspect(other)}"
  end

  defp defaults(spec) do
    if Keyword.keyword?(spec),
      do: for({name, opts} <- spec, Keyword.keyword?(opts), Keyword.has_key?(opts, :default), do: name),
      else: []
  end

  defp type_fields!(type, spec, skipped, mode, where) do
    fields = spec_fields!(spec, mode, where)
    check_struct!(type, Keyword.keys(spec), skipped, where)

    fields
  end

  defp check_struct!(type, names, skipped, where) do
    struct_module!(type, where)

    struct_keys = Map.keys(type.__struct__()) -- (@skipped_keys ++ skipped)

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

  defp spec_fields!(spec, mode, where) do
    if not Keyword.keyword?(spec) or spec == [] do
      raise CompileError, description: "#{where}: непустой keyword-список полей"
    end

    FieldCheck.unique!(Keyword.keys(spec), where)
    fields = Enum.map(spec, fn {name, opts} -> field!(name, opts, mode, "#{where}, поле #{name}") end)
    FieldCheck.unique!(Enum.map(fields, fn %__MODULE__{wire: wire} -> wire end), "#{where}, wire-ключи")

    fields
  end

  defp field!(name, opts, mode, where) do
    if not Keyword.keyword?(opts) do
      raise CompileError, description: "#{where}: keyword-спека"
    end

    case Keyword.keys(opts) -- (@kind_keys ++ @extra_keys ++ if(mode == :payload, do: [:subject], else: [])) do
      [] -> :ok
      unknown -> raise CompileError, description: "#{where}: неизвестные ключи #{inspect(unknown)}"
    end

    spec = spec!(opts, where)
    optional? = optional!(opts, where)

    %__MODULE__{
      name: name,
      spec: spec,
      optional?: optional?,
      wire: wire!(name, opts, where),
      default: default!(opts, spec, optional?, mode != :dump_only, where),
      subject: subject!(opts, where)
    }
  end

  defp spec!(opts, where) do
    case Keyword.take(opts, @kind_keys) do
      [{kind, value}] ->
        kind_spec!(kind, value, where)

      other ->
        raise CompileError,
          description:
            "#{where}: нужен ровно один из #{Enum.map_join(@kind_keys, "/", &"#{&1}:")}, задано #{inspect(other)}"
    end
  end

  defp kind_spec!(:prim, mod, where) do
    FieldCheck.prim!(mod, where)
    {:prim, mod}
  end

  defp kind_spec!(:enum, mod, where) do
    FieldCheck.enum!(mod, where)
    {:enum, mod}
  end

  defp kind_spec!(:entity, mod, where) do
    struct_module!(mod, where)
    {:entity, mod}
  end

  # Семейство struct не имеет: struct здесь — вариант или Prim, а модуль `Core.Enum` — enum, и поле
  # с ними работало бы на одном значении и молча ломалось на остальных.
  defp kind_spec!(:union, mod, where) do
    FieldCheck.module!(mod, where)

    cond do
      Core.Helper.Module.exports?(mod, :__struct__, 0) ->
        raise CompileError,
          description: "#{where}: union: #{inspect(mod)} — struct, а не семейство; нужен entity: или prim:"

      Core.Enum.enum?(mod) ->
        raise CompileError, description: "#{where}: union: #{inspect(mod)} — Core.Enum, а не семейство; нужен enum:"

      true ->
        {:union, mod}
    end
  end

  defp kind_spec!(:list, inner, where) do
    if not Keyword.keyword?(inner) do
      raise CompileError, description: "#{where}: list: keyword-спека элемента"
    end

    if Keyword.has_key?(inner, :optional) do
      raise CompileError, description: "#{where}: optional: задаётся у самого поля, не в list:"
    end

    case Keyword.keys(inner) -- @kind_keys do
      [] -> {:list, spec!(inner, where)}
      unknown -> raise CompileError, description: "#{where}: list: неизвестные ключи #{inspect(unknown)}"
    end
  end

  defp kind_spec!(:type, type, _where) when type in @type_values, do: {:type, type}

  defp kind_spec!(:type, type, where) do
    raise CompileError,
      description: "#{where}: неизвестный type: #{inspect(type)}, ожидается один из #{inspect(@type_values)}"
  end

  defp optional!(opts, where) do
    case Keyword.get(opts, :optional, false) do
      optional? when is_boolean(optional?) -> optional?
      other -> raise CompileError, description: "#{where}: optional: boolean, задано #{inspect(other)}"
    end
  end

  defp wire!(name, opts, where) do
    case Keyword.fetch(opts, :wire) do
      :error -> Atom.to_string(name)
      {:ok, wire} when is_binary(wire) and wire != "" -> wire
      {:ok, other} -> raise CompileError, description: "#{where}: wire: непустая строка, задано #{inspect(other)}"
    end
  end

  defp default!(opts, spec, optional?, loadable?, where) do
    case {Keyword.fetch(opts, :default), optional?, loadable?} do
      {:error, _optional?, _loadable?} ->
        :none

      {{:ok, _default}, true, _loadable?} ->
        raise CompileError, description: "#{where}: default: и optional: true — два ответа на один nil"

      {{:ok, _default}, false, false} ->
        raise CompileError, description: "#{where}: default: при loadable: false не применяется — загрузки нет"

      {{:ok, default}, false, true} ->
        check_default!(spec, default, where)
        {:default, default}
    end
  end

  defp subject!(opts, where) do
    case Keyword.fetch(opts, :subject) do
      :error ->
        nil

      {:ok, subject} when is_atom(subject) and subject not in ~w(nil true false)a ->
        subject

      {:ok, other} ->
        raise CompileError,
          description: "#{where}: subject: атом — :aggregate_id или имя поля нагрузки, задано #{inspect(other)}"
    end
  end

  # Нагрузка события: wire-ключ на `$` совпал бы с зарезервированной формой `{"$pd": …}` (ADR-0073).
  defp check_payload_wires!(fields, where) do
    Enum.each(fields, fn %__MODULE__{name: name, wire: wire} -> check_wire!(wire, "#{where}, поле #{name}") end)

    fields
  end

  defp check_wire!("$" <> _rest = wire, where) do
    raise CompileError,
      description: "#{where}: wire-ключ #{inspect(wire)} начинается с $ — форма {\"$pd\": …} зарезервирована"
  end

  defp check_wire!(_wire, _where), do: :ok

  # Загрузку Prim и сущности без фасада не повторить, а `cast` enum — чистая функция модуля:
  # опечатка в `default:` всплыла бы только на строке, записанной до появления поля.
  defp check_default!({:enum, mod}, default, where) do
    case mod.cast(default) do
      {:ok, _value} ->
        :ok

      {:error, _reason} ->
        raise CompileError, description: "#{where}: default: #{inspect(default)} не загружается #{inspect(mod)}"
    end
  end

  defp check_default!(_spec, _default, _where), do: :ok

  # ===== субъекты =====

  @doc "Поля нагрузки события с `subject:`: `[{поле, субъект}]` в порядке объявления."
  @spec subjects([t()]) :: [{atom(), atom()}]

  def subjects(fields) when is_list(fields),
    do: for(%__MODULE__{name: name, subject: subject} <- fields, not is_nil(subject), do: {name, subject})

  # ===== тип =====

  @doc false
  @spec typespec([t()]) :: keyword(Macro.t())

  def typespec(fields) do
    Enum.map(fields, fn
      %__MODULE__{name: name, spec: spec, optional?: false} -> {name, spec_type(spec)}
      %__MODULE__{name: name, spec: spec, optional?: true} -> {name, quote(do: unquote(spec_type(spec)) | nil)}
    end)
  end

  # ---

  defp spec_type({:union, _family}), do: quote(do: struct())
  defp spec_type({kind, mod}) when kind in ~w(prim enum entity)a, do: quote(do: unquote(mod).t())
  defp spec_type({:list, inner}), do: quote(do: [unquote(spec_type(inner))])
  defp spec_type({:type, :string}), do: quote(do: String.t())
  defp spec_type({:type, scalar}), do: quote(do: unquote(scalar)())
end
