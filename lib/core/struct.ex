defmodule Core.Struct do
  @moduledoc """
  Структура по полям: `defstruct`, обязательные ключи и `@type t` из одной декларации на языке
  спеки полей (`Core.Codec.Field`, ADR-0090).

      defmodule Rename do
        defmodule Note do
          use Core.Prim.String,
            name: "Заметка",
            max_len: 200
        end

        use Core.Struct,
          fields: [
            id: [prim: Account.ID],
            name: [prim: Account.Name],
            note: [prim: Note, optional: true],
            status: [enum: Account.Status, default: :active],
            tags: [list: [prim: Account.Tag], default: []],
            reason: [prim: Note, optional: true, default: nil],
            at: [prim: Core.Es.Event.At],
            by: [prim: User.ID]
          ]
      end

      %Rename{id: id, name: name, note: nil, at: at, by: by}

  Поле хранит значение своего вида: Prim — сам Prim, а не извлечённое из него значение. Wire у
  структуры нет — формат наружу задаёт Codec-плагин по полям; конструктора нет — struct собирается
  литералом `%Rename{}`.

  | Вид | Значение | В `@type t` |
  |---|---|---|
  | `prim: Mod` | Prim-модуль | `Mod.t()` |
  | `enum: Mod` | модуль `Core.Enum` | `Mod.t()` |
  | `entity: Mod` | struct-модуль | `Mod.t()` |
  | `union: Mod` | семейство вариантов | `struct()` |
  | `list: [<вид>]` | спека элемента | `[<тип элемента>]` |
  | `type: :string` | строка | `String.t()` |
  | `type: :boolean` / `:integer` / `:pos_integer` / `:non_neg_integer` / `:map` | примитив | `boolean()` / … |

  `optional: true` допускает `nil` в значении поля: к типу добавляется `| nil`. Обязательность ключа
  задаёт только `default:` — значение поля по умолчанию: пока его нет, каждая сборка `%Rename{}`
  указывает ключ явно, и новое поле роняет сборку каждого литерала, а не даёт тихий `nil`.

  | `optional:` | `default:` | Ключ в `%Rename{}` | В `@type t` |
  |---|---|---|---|
  | — | — | обязателен | `T` |
  | `true` | — | обязателен | `T \\| nil` |
  | — | значение | можно не указывать | `T` |
  | `true` | `nil` или значение | можно не указывать | `T \\| nil` |

  `default:` — опция-выражение внутри литерального `fields:` (`docs/rules/20-agreements.md`,
  «Опции `use`»): литерал, вызов чистой функции Prim (`Currency.new!("RUB")`,
  `DeliveryID.from_number!(42)`) или атрибут модуля, объявленный выше `use` (`@rub`). Выражение
  вычисляется в теле модуля, и сборка проверяет вид результата: `prim:` — struct этого Prim, `enum:` —
  значение Enum, `type:` — значение типа, `entity:` — struct модуля, `union:` — struct, но не Prim
  (принадлежность семейству не проверяется: варианты объявляет кодек), `list:` — список,
  поэлементно; `nil` — только при `optional: true`.

  > #### Значение вычисляется один раз {: .warning}
  >
  > `default:` вычисляется при сборке модуля, и все struct получают это одно значение.
  > `default: CreatedAt.now!()` или `default: ID.generate()` собираются, но дают момент и
  > идентификатор сборки, а не создания struct, — это ошибка; сборка её не ловит.

  Порождаются в месте `use`:

  - `@enforce_keys` — поля без `default:`;
  - `defstruct` — значения по умолчанию, у поля без `default:` — `nil`;
  - `@type t` по видам полей;
  - `__struct_fields__/0` — внутренняя для builder'ов ролей: нормализованные поля спеки, форма — не
    контракт; у собранного модуля её читает `Core.Codec.Field.struct_fields/1`.

  Макрос занимает в модуле имя `@core_struct_fields`: поля спеки структуры, которая ещё собирается,
  отдаёт `declared_fields/1` — по нему `use Core.Labels.Fields` ниже берёт вид полей, и подписям
  хватает `labels:`.

  `fields:`, кроме значений `default:`, — литерал (`docs/rules/20-agreements.md`, «Опции `use`»):
  атрибут или вызов функции — `CompileError` «ожидается литерал». Модули спеки проверяются в теле
  модуля, поэтому MAY быть вложены в него выше `use`.

  `CompileError` с префиксом `Struct: fields: <поле>: …`:

  - `wire:` и `subject:` — без кодека они ничего не значат;
  - `default:` не того вида, `default: nil` без `optional: true`;
  - `default:`, в значении которого есть Prim `personal: true` или `sensitive:`, в том числе внутри
    struct и списка, — значение ушло бы в исходник и байткод (`default: nil` у такого поля допустим);
  - `prim:` не Prim, `enum:` не `Core.Enum`, `entity:` не struct, `union:` — struct или `Core.Enum`;
  - несобранный модуль, неизвестное значение `type:`, неизвестный ключ, не ровно один вид;
  - повтор поля.
  """

  alias Core.Codec.Field
  alias Core.Helper
  alias Core.Helper.FieldCheck
  alias Core.Prim

  @label "Struct"
  @required_keys ~w(fields)a
  @optional_keys ~w()a
  @expression_keys [fields: ~w(default)a]

  # ===== декларация =====

  @doc "Объявить структуру по полям (`fields:`)."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)
    {fields, defaults} = split_defaults(Keyword.fetch!(opts, :fields))

    [
      quote do
        @core_struct_fields Core.Struct.fields!(unquote(Macro.escape(fields)))
        @core_struct_fields Core.Struct.default!(@core_struct_fields, unquote(defaults))
      end,
      quote unquote: false do
        @enforce_keys for %Core.Codec.Field{name: name, default: :none} <- @core_struct_fields, do: name
        defstruct Enum.map(@core_struct_fields, fn
                    %Core.Codec.Field{name: name, default: {:default, value}} -> {name, value}
                    %Core.Codec.Field{name: name, default: :none} -> {name, nil}
                  end)

        @type t :: %__MODULE__{unquote_splicing(Core.Codec.Field.typespec(@core_struct_fields))}

        @doc false
        @spec __struct_fields__() :: [Core.Codec.Field.t()]

        def __struct_fields__, do: @core_struct_fields
      end
    ]
  end

  # ---

  defp split_defaults(fields) do
    if Keyword.keyword?(fields),
      do:
        {Enum.map(fields, &without_default/1),
         for({name, spec} <- fields, {:ok, ast} <- [default(spec)], do: {name, ast})},
      else: {fields, []}
  end

  defp without_default({name, spec}),
    do: {name, if(Keyword.keyword?(spec), do: Keyword.delete(spec, :default), else: spec)}

  defp default(spec), do: if(Keyword.keyword?(spec), do: Keyword.fetch(spec, :default), else: :error)

  # ===== поля =====

  @doc false
  @spec declared_fields(module()) :: [Field.t()] | nil

  def declared_fields(module) when is_atom(module), do: Module.get_attribute(module, :core_struct_fields)

  @doc false
  @spec fields!(term()) :: [Field.t()]

  def fields!(spec) do
    where = "#{@label}: fields"
    check_unique!(spec, where)

    Field.normalize!(spec, :struct, where)
  end

  # ---

  defp check_unique!(spec, where) do
    if Keyword.keyword?(spec) do
      case Keyword.keys(spec) -- Enum.uniq(Keyword.keys(spec)) do
        [] -> :ok
        [name | _rest] -> Helper.Opts.reject!("#{where}: #{name}", "поле объявлено повторно")
      end
    end
  end

  # ===== default: =====

  @doc false
  @spec default!([Field.t()], keyword()) :: [Field.t()]

  def default!(fields, values) when is_list(fields) and is_list(values) do
    Enum.map(fields, fn %Field{name: name} = field ->
      case Keyword.fetch(values, name) do
        :error -> field
        {:ok, value} -> %{field | default: {:default, value!(field, value)}}
      end
    end)
  end

  # ---

  defp value!(%Field{name: name, spec: spec, optional?: optional?}, value) do
    where = "#{@label}: fields: #{name}: default"

    cond do
      not is_nil(value) -> check_value!(spec, value, where)
      optional? -> :ok
      true -> Helper.Opts.reject!(where, "nil без optional: true — тип поля не допускает nil")
    end

    check_public!(value, where)

    value
  end

  defp check_value!({:prim, mod}, value, where),
    do: expect!(is_struct(value, mod), where, "Prim #{inspect(mod)}", value)

  defp check_value!({:enum, mod}, value, where),
    do: expect!(value in mod.values(), where, "значение #{inspect(mod)}", value)

  defp check_value!({:entity, mod}, value, where),
    do: expect!(is_struct(value, mod), where, "%#{inspect(mod)}{}", value)

  defp check_value!({:union, family}, value, where),
    do: expect!(variant?(value), where, "вариант #{inspect(family)}", value)

  defp check_value!({:list, inner}, values, where) when is_list(values),
    do: Enum.each(values, &check_value!(inner, &1, where))

  defp check_value!({:list, _inner}, value, where), do: mismatch!(where, "список", value)

  defp check_value!({:type, type}, value, where),
    do: expect!(FieldCheck.type_value?(type, value), where, "#{type}", value)

  defp variant?(%mod{}), do: not Prim.prim?(mod)
  defp variant?(_value), do: false

  defp expect!(true = _valid?, _where, _expected, _value), do: :ok
  defp expect!(false = _valid?, where, expected, value), do: mismatch!(where, expected, value)

  @spec mismatch!(String.t(), String.t(), term()) :: no_return()

  defp mismatch!(where, expected, value),
    do: Helper.Opts.reject!(where, "ожидается #{expected}, получено #{inspect(value)}")

  defp check_public!(value, where) do
    case secret_prim(value) do
      nil ->
        :ok

      mod ->
        Helper.Opts.reject!(
          where,
          "значение Prim #{inspect(mod)} с personal: true или sensitive: ушло бы в исходник и байткод"
        )
    end
  end

  defp secret_prim(%mod{} = value) do
    cond do
      not Prim.prim?(mod) -> secret_prim(Map.values(Map.from_struct(value)))
      mod.__domain_personal__() or mod.__domain_sensitive__() -> mod
      true -> nil
    end
  end

  defp secret_prim(%{} = map), do: secret_prim(Map.to_list(map))
  defp secret_prim(list) when is_list(list), do: Enum.find_value(list, &secret_prim/1)
  defp secret_prim(tuple) when is_tuple(tuple), do: secret_prim(Tuple.to_list(tuple))
  defp secret_prim(_value), do: nil
end
