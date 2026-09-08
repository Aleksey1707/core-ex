defmodule Core.View.Dumper do
  @moduledoc """
  Генерация вложенного `Codec` представления — dump-only плагина фасада.

  Дамп тотален по значению на всю глубину: read-путь не валидирует и не имеет права падать
  на одной строке (`13-repos.md`). `nil` и неприводимое значение проходят как есть, поле
  формы читается по atom- или одноимённому строковому ключу, не-map на месте формы и
  не-список на месте `list:` возвращаются без изменений.
  """

  alias Core.View.Opts

  @label "View"
  @item_vars ~w(item_0 item_1 item_2 item_3)a

  @doc false
  @spec codec_ast(module(), [Opts.field()], [{atom(), [Opts.field()]}]) :: Macro.t()

  def codec_ast(view, fields, forms) do
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

  @doc false
  @spec map_list(term(), (term() -> term())) :: term()

  def map_list(nil, _fun), do: nil
  def map_list(list, fun) when is_list(list), do: Enum.map(list, fun)
  def map_list(other, _fun), do: other

  # ---

  # Формы дампятся одной функцией с именем формы аргументом, а не функцией на форму:
  # имя формы — атом из декларации, а `:"dump_#{name}"` собирал бы атом в рантайме.
  defp form_dumpers_ast([]), do: []

  defp form_dumpers_ast(forms) do
    [quote(do: defp(dump_form(_name, nil, _codec), do: nil))] ++
      Enum.map(forms, &form_dumper_ast/1) ++
      [quote(do: defp(dump_form(_name, other, _codec), do: other))]
  end

  defp form_dumper_ast({name, fields}) do
    codec = codec_var(fields_need_codec?(fields))
    form = Macro.var(:form, __MODULE__)

    pairs =
      Enum.map(fields, fn {field, spec, _optional?} ->
        {field, dump_ast(spec, form_access(form, field), codec, 0)}
      end)

    quote do
      defp dump_form(unquote(name), unquote(form), unquote(codec)) when is_map(unquote(form)) do
        unquote({:%{}, [], pairs})
      end
    end
  end

  defp dump_ast({:prim, mod, _kind}, value, codec, _depth) do
    quote do
      Core.Codec.Helper.dump_raw(unquote(mod), unquote(value), unquote(codec))
    end
  end

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
      Core.View.Dumper.map_list(unquote(value), fn unquote(item) ->
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
      description:
        "#{@label}: вложенность списков #{depth} глубже допустимой (#{length(@item_vars)})"
  end

  defp field_access(value, name), do: {{:., [], [value, name]}, [no_parens: true], []}

  # jsonb после round-trip через Postgres приходит со строковыми ключами, а read-путь не
  # имеет права падать на одной строке (`13-repos.md`): обязательность поля держит `@type`.
  defp form_access(form, field) do
    quote(do: Core.Helper.Map.field(unquote(form), unquote(field)))
  end
end
