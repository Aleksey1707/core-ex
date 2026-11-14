defmodule Core.View.Dumper do
  @moduledoc """
  Генерация вложенного `Codec` представления — dump-only плагина фасада.

  Дамп тотален по значению на всю глубину: read-путь не валидирует и не имеет права падать
  на одной строке (`13-repos.md`). `nil` и неприводимое значение проходят как есть, поле
  формы читается по atom- или одноимённому строковому ключу, не-map на месте формы и
  не-список на месте `list:` возвращаются без изменений.
  """

  alias Core.View.Field

  @doc false
  @spec codec_ast(module(), [Field.t()], [{atom(), [Field.t()]}]) :: Macro.t()

  def codec_ast(view, fields, forms) do
    codec = codec_var(fields_need_codec?(fields))
    value = Macro.var(:view, __MODULE__)

    pairs =
      Enum.map(fields, fn %Field{name: name, dump_ast: dump_ast} ->
        {name, dump_ast.(field_access(value, name), codec)}
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

  @doc false
  @spec map_set(term(), (term() -> term())) :: term()

  def map_set(nil, _fun), do: nil
  def map_set(%MapSet{} = set, fun), do: Core.Codec.Helper.set_wire(Enum.map(set, fun))
  def map_set(list, fun) when is_list(list), do: Core.Codec.Helper.set_wire(Enum.map(list, fun))
  def map_set(other, _fun), do: other

  @doc false
  @spec map_dict(term(), (term() -> term()), (term() -> term())) :: term()

  def map_dict(nil, _key_fun, _value_fun), do: nil

  def map_dict(map, key_fun, value_fun) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {key_fun.(key), value_fun.(value)} end)

  def map_dict(other, _key_fun, _value_fun), do: other

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
      Enum.map(fields, fn %Field{name: field, dump_ast: dump_ast} ->
        {field, dump_ast.(form_access(form, field), codec)}
      end)

    quote do
      defp dump_form(unquote(name), unquote(form), unquote(codec)) when is_map(unquote(form)) do
        unquote({:%{}, [], pairs})
      end
    end
  end

  defp fields_need_codec?(fields), do: Enum.any?(fields, & &1.needs_codec?)

  defp codec_var(true), do: Macro.var(:codec, __MODULE__)
  defp codec_var(false), do: Macro.var(:_codec, __MODULE__)

  defp field_access(value, name), do: {{:., [], [value, name]}, [no_parens: true], []}

  # jsonb после round-trip через Postgres приходит со строковыми ключами, а read-путь не
  # имеет права падать на одной строке (`13-repos.md`): обязательность поля держит `@type`.
  defp form_access(form, field) do
    quote(do: Core.Helper.Map.field(unquote(form), unquote(field)))
  end
end
