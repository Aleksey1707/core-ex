defmodule Core.Struct do
  @moduledoc """
  Структура по полям: `defstruct`, обязательные ключи и `@type t` из одной декларации на языке
  спеки полей (`Core.Codec.Field`, ADR-0090).

      defmodule Rename do
        defmodule Note do
          use Core.Prim.String, name: "Заметка", max_len: 200
        end

        use Core.Struct,
          fields: [
            id: [prim: Account.ID],
            name: [prim: Account.Name],
            note: [prim: Note, optional: true],
            status: [enum: Account.Status],
            tags: [list: [prim: Account.Tag]],
            at: [prim: Core.Es.Event.At],
            by: [prim: User.ID]
          ]
      end

      %Rename{id: id, name: name, note: nil, status: :active, tags: [], at: at, by: by}

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

  `optional: true` допускает `nil` в значении поля: к типу добавляется `| nil`. Ключ при этом остаётся
  обязательным — каждая сборка `%Rename{}` указывает его явно, и новое поле роняет сборку каждого
  литерала, а не даёт тихий `nil`.

  Порождаются в месте `use`:

  - `@enforce_keys` и `defstruct` — все поля;
  - `@type t` по видам полей;
  - `__struct_fields__/0` — внутренняя для builder'ов ролей: нормализованные поля спеки, форма — не
    контракт.

  `fields:` — литерал (`docs/rules/20-agreements.md`, «Опции `use`»): атрибут или вызов функции —
  `CompileError` «ожидается литерал». Модули спеки проверяются в теле модуля, поэтому MAY быть
  вложены в него выше `use`.

  `CompileError` с префиксом `Struct: fields: <поле>: …`:

  - `wire:` и `subject:` — без кодека они ничего не значат;
  - `default:` — пока не поддерживается;
  - `prim:` не Prim, `enum:` не `Core.Enum`, `entity:` не struct, `union:` — struct или `Core.Enum`;
  - несобранный модуль, неизвестное значение `type:`, неизвестный ключ, не ровно один вид;
  - повтор поля.
  """

  alias Core.Codec.Field
  alias Core.Helper

  @label "Struct"
  @required_keys ~w(fields)a
  @optional_keys ~w()a
  @expression_keys ~w()a

  @doc "Объявить структуру по полям (`fields:`)."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)

    [
      quote do
        @core_struct_fields Core.Struct.fields!(unquote(Macro.escape(Keyword.fetch!(opts, :fields))))
      end,
      quote unquote: false do
        @enforce_keys for %Core.Codec.Field{name: name} <- @core_struct_fields, do: name
        defstruct for %Core.Codec.Field{name: name} <- @core_struct_fields, do: name

        @type t :: %__MODULE__{unquote_splicing(Core.Codec.Field.typespec(@core_struct_fields))}

        @doc false
        @spec __struct_fields__() :: [Core.Codec.Field.t()]

        def __struct_fields__, do: @core_struct_fields
      end
    ]
  end

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
end
