defmodule Core.View do
  @moduledoc """
  Билдер read-модели: структура представления и её dump-only кодек из одной декларации.

  ```elixir
  use Core.View,
    fields: [
      id: [prim: Agg.ID],
      status: [enum: Agg.Status],
      version: [type: :pos_integer],
      created_at: [prim: Agg.CreatedAt],
      closed_at: [prim: Agg.ClosedAt, optional: true]
    ]
  ```

  Поле объявляется тем **Prim**, которым оно живёт в домене, — из него берутся и тип
  (`String.t()`, `DateTime.t()`, `Decimal.t()`), и wire-формат (`Codec.dump_raw_as/2`:
  kind плюс tz и precision этого Prim). Поэтому read-путь не может разойтись с
  агрегатным, а поле, добавленное в структуру, не может остаться недампленным: и то и
  другое порождает одна и та же строка декларации.

  Значения во View — примитивные (`13-repos.md`): Prim в спеке задаёт формат, но в
  структуру не попадает. Sensitive Prim отвергается — чувствительному значению не место
  в read-модели.

  ## Виды полей

  | Ключ | Значение | Дамп |
  |---|---|---|
  | `prim:` | Prim-модуль | `codec.dump_raw_as/2` (kind `:string` / `:integer` — как есть) |
  | `enum:` | модуль `Core.Enum` | атом как есть |
  | `type:` | `:string` / `:boolean` / `:integer` / `:pos_integer` / `:non_neg_integer` | как есть |
  | `view:` | вложенный View | его кодеком через фасад |
  | `form:` | имя формы из `forms:` | сгенерированным `dump_<форма>/2` |
  | `list:` | вложенная спека | поэлементно |
  | `jsonb:` | `{Модуль, :функция}` спеки `Core.Codec.Redump` | пере-дампом нагрузки |

  `optional: true` выводит поле из `@enforce_keys` и добавляет `| nil` в тип.

  `forms:` объявляет именованные map-формы вложенных значений (`stage`, `item_progress`):
  у них появляется свой `@type`, на который могут ссылаться read-схемы.

  Генерируются `@enforce_keys`, `defstruct`, `@type t`, `new/1` (keyword) и вложенный
  `Codec` — dump-only плагин фасада (`loadable: false`), который регистрируется в
  `Codec.plugins()` наравне с остальными.
  """

  alias Core.Helper
  alias Core.View.Opts

  @formattable_kinds ~w(uuid datetime date decimal)a
  @item_vars ~w(item_0 item_1 item_2 item_3)a

  @doc "Объявить представление read-пути (`fields:` + опционально `forms:`)."
  defmacro __using__(opts) do
    view = __CALLER__.module
    opts = Macro.expand_literals(opts, __CALLER__)
    Helper.Opts.validate!(opts, ~w(fields)a, ~w(forms)a, "View")

    forms = Opts.forms!(Keyword.get(opts, :forms, []))
    fields = Opts.fields!(Keyword.fetch!(opts, :fields), Keyword.keys(forms))
    check_forms_used!(fields, forms)

    quote do
      unquote(struct_ast(fields))
      unquote(forms_types_ast(forms))
      unquote(type_t_ast(fields))
      unquote(new_ast(fields))
      unquote(codec_ast(view, fields, forms))
    end
  end

  @doc false
  @spec map_list(term(), (term() -> term())) :: term()

  def map_list(nil, _fun), do: nil
  def map_list(list, fun) when is_list(list), do: Enum.map(list, fun)
  def map_list(other, _fun), do: other

  # ---

  defp check_forms_used!(fields, forms) do
    used =
      Enum.reduce(forms, Opts.used_forms(fields), fn {_name, form_fields}, acc ->
        MapSet.union(acc, Opts.used_forms(form_fields))
      end)

    case Enum.reject(Keyword.keys(forms), &MapSet.member?(used, &1)) do
      [] ->
        :ok

      unused ->
        raise CompileError,
          description: "View: формы #{inspect(unused)} объявлены, но не используются"
    end
  end

  defp struct_ast(fields) do
    required = for {name, _spec, false} <- fields, do: name
    all = Enum.map(fields, fn {name, _spec, _optional?} -> name end)

    quote do
      @enforce_keys unquote(required)
      defstruct unquote(all)
    end
  end

  defp forms_types_ast(forms) do
    for {name, fields} <- forms do
      quote do
        @typedoc "Форма `#{unquote(name)}` представления."
        @type unquote({name, [], nil}) :: unquote(map_type_ast(fields))
      end
    end
  end

  defp type_t_ast(fields) do
    quote do
      @type t :: %__MODULE__{unquote_splicing(type_pairs(fields))}
    end
  end

  defp map_type_ast(fields), do: {:%{}, [], type_pairs(fields)}

  defp type_pairs(fields) do
    Enum.map(fields, fn {name, spec, optional?} ->
      {name, optional_type_ast(type_ast(spec), optional?)}
    end)
  end

  defp optional_type_ast(type, false), do: type
  defp optional_type_ast(type, true), do: quote(do: unquote(type) | nil)

  defp type_ast({:prim, _mod, kind}) when kind in ~w(uuid string)a, do: quote(do: String.t())
  defp type_ast({:prim, _mod, :datetime}), do: quote(do: DateTime.t())
  defp type_ast({:prim, _mod, :date}), do: quote(do: Date.t())
  defp type_ast({:prim, _mod, :decimal}), do: quote(do: Decimal.t())
  defp type_ast({:prim, _mod, :integer}), do: quote(do: integer())
  defp type_ast({:enum, mod}), do: quote(do: unquote(mod).t())
  defp type_ast({:view, mod}), do: quote(do: unquote(mod).t())
  defp type_ast({:type, :string}), do: quote(do: String.t())
  defp type_ast({:type, type}), do: {type, [], []}
  defp type_ast({:form, name}), do: {name, [], []}
  defp type_ast({:list, inner}), do: quote(do: [unquote(type_ast(inner))])
  defp type_ast({:jsonb, _spec_ref}), do: quote(do: map())

  defp new_ast(fields) do
    quote do
      @doc "Собрать представление из keyword-списка полей."
      @spec new(keyword()) :: t()

      def new(opts) when is_list(opts) do
        %__MODULE__{unquote_splicing(new_pairs(fields))}
      end
    end
  end

  defp new_pairs(fields) do
    Enum.map(fields, fn
      {name, _spec, false} -> {name, quote(do: Keyword.fetch!(opts, unquote(name)))}
      {name, _spec, true} -> {name, quote(do: Keyword.get(opts, unquote(name)))}
    end)
  end

  defp codec_ast(view, fields, forms) do
    codec = codec_var(fields_need_codec?(fields))
    value = Macro.var(:view, __MODULE__)

    pairs =
      Enum.map(fields, fn {name, spec, _optional?} ->
        {name, dump_ast(spec, field_access(value, name), codec, 0)}
      end)

    quote do
      defmodule Codec do
        @moduledoc unquote("Кодек представления `#{inspect(view)}` (dump-only).")

        use Core.Codec.Plugin,
          types: [unquote(view)],
          loadable: false

        @doc "Представление → map полей."
        @spec dump(unquote(view).t(), module()) :: map()

        @impl true
        def dump(%unquote(view){} = unquote(value), unquote(codec)) do
          unquote({:%{}, [], pairs})
        end

        unquote_splicing(form_dumpers_ast(forms))
      end
    end
  end

  # Формы дампятся одной функцией с именем формы аргументом, а не функцией на форму:
  # имя формы — атом из декларации, а `:"dump_#{name}"` собирал бы атом в рантайме.
  defp form_dumpers_ast([]), do: []

  defp form_dumpers_ast(forms) do
    [
      quote(do: defp(dump_form(_name, nil, _codec), do: nil))
      | Enum.map(forms, &form_dumper_ast/1)
    ]
  end

  defp form_dumper_ast({name, fields}) do
    codec = codec_var(fields_need_codec?(fields))
    form = Macro.var(:form, __MODULE__)

    pairs =
      Enum.map(fields, fn {field, spec, optional?} ->
        {field, dump_ast(spec, form_access(form, field, optional?), codec, 0)}
      end)

    quote do
      defp dump_form(unquote(name), unquote(form), unquote(codec)) when is_map(unquote(form)) do
        unquote({:%{}, [], pairs})
      end
    end
  end

  defp dump_ast({:prim, mod, kind}, value, codec, _depth) when kind in @formattable_kinds do
    quote(do: unquote(codec).dump_raw_as(unquote(mod), unquote(value)))
  end

  defp dump_ast({:prim, _mod, _plain_kind}, value, _codec, _depth), do: value
  defp dump_ast({:enum, _mod}, value, _codec, _depth), do: value
  defp dump_ast({:type, _type}, value, _codec, _depth), do: value

  defp dump_ast({:view, _mod}, value, codec, _depth) do
    quote(do: Core.Codec.Helper.dump_optional(unquote(value), unquote(codec)))
  end

  defp dump_ast({:form, name}, value, codec, _depth) do
    quote(do: dump_form(unquote(name), unquote(value), unquote(codec)))
  end

  defp dump_ast({:jsonb, {mod, fun}}, value, codec, _depth) do
    quote do
      Core.Codec.Redump.run(unquote(value), unquote(mod).unquote(fun)(), unquote(codec))
    end
  end

  defp dump_ast({:list, inner}, value, codec, depth) do
    item = Macro.var(item_var!(depth), __MODULE__)

    quote do
      Core.View.map_list(unquote(value), fn unquote(item) ->
        unquote(dump_ast(inner, item, codec, depth + 1))
      end)
    end
  end

  defp fields_need_codec?(fields) do
    Enum.any?(fields, fn {_name, spec, _optional?} -> Opts.needs_codec?(spec) end)
  end

  defp codec_var(true), do: Macro.var(:codec, __MODULE__)
  defp codec_var(false), do: Macro.var(:_codec, __MODULE__)

  # Имена переменных элементов перечислены заранее: собирать их интерполяцией значило бы
  # заводить атомы в рантайме. Вложенность глубже — не форма представления, а недосмотр.
  defp item_var!(depth) when depth < length(@item_vars), do: Enum.at(@item_vars, depth)

  defp item_var!(depth) do
    raise CompileError,
      description: "View: вложенность списков #{depth} глубже допустимой (#{length(@item_vars)})"
  end

  defp field_access(value, name), do: {{:., [], [value, name]}, [no_parens: true], []}

  defp form_access(form, field, false), do: quote(do: Map.fetch!(unquote(form), unquote(field)))
  defp form_access(form, field, true), do: quote(do: Map.get(unquote(form), unquote(field)))
end
