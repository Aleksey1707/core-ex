defmodule Core.View.Field do
  @moduledoc false

  alias Core.Codec
  alias Core.Helper

  @label "View"
  @item_vars ~w(item_0 item_1 item_2 item_3)a

  # Placeholder'ы AST: подставляются при генерации `new/1` и дампа. Контекст различим, чтобы
  # значение формы не совпало со значением дампа случайно.
  @shape_var Macro.var(:value, :view_shape)
  @dump_value_var Macro.var(:value, :view_dump)
  @dump_codec_var Macro.var(:codec, :view_dump)

  @prim_type_asts %{
    uuid: quote(do: String.t()),
    string: quote(do: String.t()),
    datetime: quote(do: DateTime.t()),
    date: quote(do: Date.t()),
    decimal: quote(do: Decimal.t()),
    integer: quote(do: integer())
  }

  # Kind, приводимый профилем, обязан быть и типизируем: поле объявляется Prim-модулем, а
  # значит новый native kind в `Core.Codec` без typespec оставил бы структуру без типа.
  @untyped_kinds Codec.coercible_kinds() -- Map.keys(@prim_type_asts)

  if @untyped_kinds != [] do
    raise CompileError,
      description: "#{@label}: нет typespec для kinds #{inspect(@untyped_kinds)}"
  end

  # Одна таблица проекций вида: тип, форма, дамп и признаки. Полнота сверяется с allowlist
  # View из `Core.Field.Spec`; вид без строки здесь — ошибка сборки.
  @projections %{
    prim: %{type: :prim, shape?: false, needs_codec?: true, dump: :prim},
    enum: %{type: :enum, shape?: false, needs_codec?: false, dump: :as_is},
    type: %{type: :type, shape?: false, needs_codec?: false, dump: :as_is},
    view: %{type: :view, shape?: false, needs_codec?: true, dump: :view},
    form: %{type: :form, shape?: false, needs_codec?: true, dump: :form},
    list: %{type: :list, shape?: :nested, needs_codec?: :nested, dump: :list},
    set: %{type: :set, shape?: true, needs_codec?: :nested, dump: :set},
    map: %{type: :map, shape?: true, needs_codec?: :nested, dump: :map},
    jsonb: %{type: :jsonb, shape?: false, needs_codec?: true, dump: :jsonb}
  }

  # Виды, для которых `Core.View.shape/2` обязан иметь клаузу: листья внутри контейнеров —
  # `prim`/`enum`, контейнеры — `list`/`set`/`map`. Сборка сверяет этот список с флагами
  # `shape?`; наличие самих клауз проверяет табличный тест.
  @shape_kinds ~w(prim enum list set map)a

  @enforce_keys ~w(name spec optional? type_ast shape_ast dump_ast shape? needs_codec?)a
  defstruct @enforce_keys

  @typedoc false
  @type spec ::
          {:prim, module(), atom()}
          | {:enum, module()}
          | {:type, atom()}
          | {:view, module()}
          | {:form, atom()}
          | {:list, spec()}
          | {:set, spec()}
          | {:map, spec(), spec()}
          | {:jsonb, module() | {module(), atom()}}

  @typedoc false
  @type dump_ast :: Macro.t()

  @typedoc false
  @type shape_ast :: Macro.t() | nil

  @typedoc false
  @type t :: %__MODULE__{
          name: atom(),
          spec: spec(),
          optional?: boolean(),
          type_ast: Macro.t(),
          shape_ast: shape_ast(),
          dump_ast: dump_ast(),
          shape?: boolean(),
          needs_codec?: boolean()
        }

  @doc false
  @spec check_kinds!([atom()]) :: :ok

  def check_kinds!(kinds) when is_list(kinds) do
    check_projections!(kinds)
    check_shape!(kinds)

    # Строки проекций проверены выше: helper добирает только виды вне allowlist, сохраняя
    # прежний текст для отсутствующего вида.
    Core.Field.Spec.check_kinds!(:view, Map.keys(@projections), [], @label)
  end

  @doc false
  @spec shape_kinds() :: [atom()]

  def shape_kinds, do: @shape_kinds

  @doc false
  @spec build(atom(), spec(), boolean()) :: t()

  def build(name, spec, optional?) when is_atom(name) and is_boolean(optional?) do
    shape? = shape?(spec)

    %__MODULE__{
      name: name,
      spec: spec,
      optional?: optional?,
      type_ast: type_ast(spec),
      shape_ast: shape_ast(spec, shape?),
      dump_ast: dump_ast(spec),
      shape?: shape?,
      needs_codec?: needs_codec?(spec)
    }
  end

  @doc false
  @spec prim_type_ast(atom()) :: Macro.t()

  def prim_type_ast(kind) when is_atom(kind), do: Map.fetch!(@prim_type_asts, kind)

  # Подстановка placeholder'ов — точной var-нодой: сгенерированный код остаётся прямыми
  # выражениями, без runtime-замыканий в IR.
  @doc false
  @spec bind_shape(Macro.t(), Macro.t()) :: Macro.t()

  def bind_shape(ast, value), do: subst(ast, %{@shape_var => value})

  @doc false
  @spec bind_dump(Macro.t(), Macro.t(), Macro.t()) :: Macro.t()

  def bind_dump(ast, value, codec), do: subst(ast, %{@dump_value_var => value, @dump_codec_var => codec})

  # ---

  defp check_projections!(kinds) do
    Enum.each(kinds, fn kind ->
      case Map.get(@projections, kind) do
        %{type: type, dump: dump, shape?: shape?, needs_codec?: codec?}
        when is_atom(type) and is_atom(dump) and shape? in [true, false, :nested] and
               codec? in [true, false, :nested] ->
          :ok

        _ ->
          raise CompileError,
            description: "#{@label}: вид #{kind}: нет всех проекций (тип, форма, дамп, признаки)"
      end
    end)
  end

  defp check_shape!(kinds) do
    for kind <- @shape_kinds, kind not in kinds do
      raise CompileError, description: "#{@label}: вид #{kind}: клауза формы вне allowlist"
    end

    for {kind, %{shape?: shape?}} <- @projections, shape? != false, kind not in @shape_kinds do
      raise CompileError, description: "#{@label}: вид #{kind}: форма без клаузы View.shape/2"
    end

    :ok
  end

  defp subst(ast, bindings) do
    Macro.prewalk(ast, fn
      {name, _meta, context} = node when is_atom(name) and is_atom(context) ->
        Map.get(bindings, node, node)

      node ->
        node
    end)
  end

  defp type_ast(spec) do
    %{type: tag} = projection(spec)
    type(tag, spec)
  end

  defp type(:prim, {:prim, _mod, kind}), do: prim_type_ast(kind)
  defp type(:enum, {:enum, mod}), do: quote(do: unquote(mod).t())
  defp type(:view, {:view, mod}), do: quote(do: unquote(mod).t())
  defp type(:type, {:type, :string}), do: quote(do: String.t())
  defp type(:type, {:type, type}), do: {type, [], []}
  defp type(:form, {:form, name}), do: {name, [], []}
  defp type(:list, {:list, inner}), do: quote(do: [unquote(type_ast(inner))])
  defp type(:set, {:set, inner}), do: quote(do: MapSet.t(unquote(type_ast(inner))))
  defp type(:map, {:map, key, value}), do: quote(do: %{optional(unquote(type_ast(key))) => unquote(type_ast(value))})
  defp type(:jsonb, {:jsonb, _spec_ref}), do: quote(do: map())

  defp shape_ast(spec, true),
    do: quote(do: Core.View.shape(unquote(Macro.escape(spec)), unquote(@shape_var)))

  defp shape_ast(_spec, false), do: nil

  defp dump_ast(spec), do: dump_expr(spec, @dump_value_var, @dump_codec_var, 0)

  defp dump_expr(spec, value, codec, depth) do
    %{dump: tag} = projection(spec)
    dump(tag, spec, value, codec, depth)
  end

  defp dump(:prim, {:prim, mod, _kind}, value, codec, _depth) do
    quote do
      Core.Codec.Helper.dump_raw(unquote(mod), unquote(value), unquote(codec))
    end
  end

  defp dump(:as_is, _spec, value, _codec, _depth), do: value

  defp dump(:view, {:view, _mod}, value, codec, _depth) do
    quote(do: Core.Codec.Helper.dump_optional(unquote(value), unquote(codec)))
  end

  defp dump(:form, {:form, name}, value, codec, _depth) do
    quote(do: dump_form(unquote(name), unquote(value), unquote(codec)))
  end

  defp dump(:jsonb, {:jsonb, type}, value, codec, _depth) when is_atom(type) do
    quote do
      Core.Codec.Redump.run(unquote(value), {:codec, unquote(type)}, unquote(codec))
    end
  end

  defp dump(:jsonb, {:jsonb, {mod, fun}}, value, codec, _depth) do
    quote do
      Core.Codec.Redump.run(unquote(value), unquote(mod).unquote(fun)(), unquote(codec))
    end
  end

  defp dump(:list, {:list, inner}, value, codec, depth) do
    item = Macro.var(item_var!(depth), __MODULE__)

    quote do
      Core.View.Dumper.map_list(unquote(value), fn unquote(item) ->
        unquote(dump_expr(inner, item, codec, depth + 1))
      end)
    end
  end

  defp dump(:set, {:set, inner}, value, codec, depth) do
    item = Macro.var(item_var!(depth), __MODULE__)

    quote do
      Core.View.Dumper.map_set(unquote(value), fn unquote(item) ->
        unquote(dump_expr(inner, item, codec, depth + 1))
      end)
    end
  end

  defp dump(:map, {:map, key, inner}, value, codec, depth) do
    key_var = Macro.var(:key, __MODULE__)
    item = Macro.var(item_var!(depth), __MODULE__)

    quote do
      Core.View.Dumper.map_dict(
        unquote(value),
        fn unquote(key_var) -> unquote(key_dump(key, key_var, codec)) end,
        fn unquote(item) -> unquote(dump_expr(inner, item, codec, depth + 1)) end
      )
    end
  end

  # Дамп тотален: строковый ключ jsonb-формы проходит как есть.
  defp key_dump({:enum, _mod}, key, _codec) do
    quote do
      if is_atom(unquote(key)) and not is_nil(unquote(key)),
        do: Core.Codec.Helper.enum_key(unquote(key)),
        else: unquote(key)
    end
  end

  defp key_dump(spec, key, codec), do: dump_expr(spec, key, codec, 0)

  defp shape?(spec) do
    case projection(spec).shape? do
      :nested -> Enum.any?(Core.Field.Spec.children(spec), &shape?/1)
      flag -> flag
    end
  end

  defp needs_codec?(spec) do
    case projection(spec).needs_codec? do
      :nested -> Enum.any?(Core.Field.Spec.children(spec), &needs_codec?/1)
      flag -> flag
    end
  end

  defp projection(spec) do
    kind = elem(spec, 0)

    case Map.fetch(@projections, kind) do
      {:ok, projection} -> projection
      :error -> raise CompileError, description: "#{@label}: вид #{kind}: нет проекций"
    end
  end

  # Имена переменных элементов перечислены заранее: собирать их интерполяцией значило бы
  # заводить атомы в рантайме. Вложенность глубже — не форма представления, а недосмотр.
  defp item_var!(depth) when depth < length(@item_vars), do: Enum.at(@item_vars, depth)

  defp item_var!(depth),
    do: Helper.Opts.reject!(@label, "вложенность списков #{depth} глубже допустимой (#{length(@item_vars)})")
end

# Полнота таблицы проверяется на сборке: функцию своего модуля нельзя вызвать в его теле, а
# отдельная функция нужна тесту и читается как контракт таблицы.
Core.View.Field.check_kinds!(Core.Field.Spec.kinds(:view))
