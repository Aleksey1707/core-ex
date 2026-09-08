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
  (`String.t()`, `DateTime.t()`, `Decimal.t()`), и wire-формат: значение приводится к
  своему Prim и дампится обычным `codec.dump/1` (`Core.Codec.Helper.dump_raw/3`). Поэтому
  read-путь не может разойтись с агрегатным, а поле, добавленное в структуру, не может
  остаться недампленным: и то и другое порождает одна и та же строка декларации.

  Значения во View — примитивные (`13-repos.md`): Prim в спеке задаёт формат, но в
  структуру не попадает. Sensitive Prim отвергается — чувствительному значению не место
  в read-модели.

  ## Виды полей

  | Ключ | Значение | Дамп |
  |---|---|---|
  | `prim:` | Prim-модуль | `Codec.Helper.dump_raw/3` (kind `:string` / `:integer` — как есть) |
  | `enum:` | модуль `Core.Enum` | атом как есть |
  | `type:` | `:string` / `:boolean` / `:integer` / `:pos_integer` / `:non_neg_integer` | как есть |
  | `view:` | вложенный View | его кодеком через фасад |
  | `form:` | имя формы из `forms:` | дампером формы (`dump_form/3`) |
  | `list:` | вложенная спека | поэлементно |
  | `jsonb:` | `{Модуль, :функция}` спеки `Core.Codec.Redump` | пере-дампом нагрузки |

  `optional: true` выводит поле из `@enforce_keys` и добавляет `| nil` в тип.

  `forms:` объявляет именованные map-формы вложенных значений (`stage`, `item_progress`):
  у них появляется свой `@type`, на который могут ссылаться read-схемы.

  Генерируются `@enforce_keys`, `defstruct`, `@type t`, `new/1` (keyword), маркер
  `__view__/0` и вложенный `Codec` — dump-only плагин фасада (`loadable: false`),
  который регистрируется в `Codec.plugins()` наравне с остальными.

  `jsonb:` типизируется `map()`; jsonb-массив объявляется `list: [jsonb: {Мод, :спека}]` —
  тогда и тип (`[map()]`), и пере-дамп идут поэлементно.

  Собирать представление в `to_view/1` SHOULD литералом `%View{...}` — неизвестный ключ там
  ловит компилятор. `new/1` — для динамической сборки: он отвергает ключ, которого нет в
  декларации (`KeyError`), иначе опечатка в имени необязательного поля ушла бы в API как `nil`.
  """

  alias Core.Helper
  alias Core.View.Dumper
  alias Core.View.Opts

  @label "View"
  @required_keys ~w(fields)a
  @optional_keys ~w(forms)a

  @doc "Объявить представление read-пути (`fields:` + опционально `forms:`)."
  defmacro __using__(opts) do
    view = __CALLER__.module
    opts = Macro.expand_literals(opts, __CALLER__)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)

    forms = Opts.forms!(Keyword.get(opts, :forms, []))
    fields = Opts.fields!(Keyword.fetch!(opts, :fields), Keyword.keys(forms))
    check_forms_used!(fields, forms)

    quote do
      unquote(marker_ast())
      unquote(struct_ast(fields))
      unquote(forms_types_ast(forms))
      unquote(type_t_ast(fields))
      unquote(new_ast(fields))
      unquote(Dumper.codec_ast(view, fields, forms))
    end
  end

  @doc false
  @spec check_keys!(module(), keyword(), [atom()]) :: :ok

  def check_keys!(view, opts, declared) do
    case Enum.uniq(Keyword.keys(opts)) -- declared do
      [] ->
        :ok

      [key | _] = unknown ->
        raise KeyError,
          key: key,
          term: view,
          message: "#{inspect(view)}: поля #{inspect(unknown)} не объявлены в представлении"
    end
  end

  # ---

  defp check_forms_used!(fields, forms) do
    used = reachable_forms(Opts.used_forms(fields), forms)

    case Enum.reject(Keyword.keys(forms), &MapSet.member?(used, &1)) do
      [] ->
        :ok

      unused ->
        raise CompileError,
          description: "#{@label}: формы #{inspect(unused)} объявлены, но не используются"
    end
  end

  # Достижимость считается от `fields:`, а не объединением всех форм: форма, на которую
  # ссылается только другая мёртвая форма, тоже мертва.
  defp reachable_forms(used, forms) do
    next =
      Enum.reduce(used, used, fn name, acc ->
        MapSet.union(acc, Opts.used_forms(Keyword.fetch!(forms, name)))
      end)

    if MapSet.equal?(next, used),
      do: used,
      else: reachable_forms(next, forms)
  end

  defp marker_ast do
    quote do
      @doc false
      @spec __view__() :: true

      def __view__, do: true
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
      @typedoc "Представление read-пути."
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
    declared = Enum.map(fields, fn {name, _spec, _optional?} -> name end)

    quote do
      @doc "Собрать представление из keyword-списка полей."
      @spec new(keyword()) :: t()

      def new(opts) when is_list(opts) do
        Core.View.check_keys!(__MODULE__, opts, unquote(declared))

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
end
