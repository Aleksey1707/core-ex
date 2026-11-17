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

  Поле хранит значение своего вида: Prim — сам Prim, а не извлечённое из него значение. Формат
  наружу задаёт Codec-плагин по полям: `wire:` структуры — тот же wire-ключ, что пишет плагин
  (расхождение — `CompileError`); конструктора нет — struct собирается литералом `%Rename{}`.

  | Вид | Значение | В `@type t` |
  |---|---|---|
  | `prim: Mod` | Prim-модуль | `Mod.t()` |
  | `enum: Mod` | модуль `Core.Enum` | `Mod.t()` |
  | `entity: Mod` | struct-модуль | `Mod.t()` |
  | `union: Mod` | семейство вариантов | `struct()` |
  | `list: [<вид>]` | спека элемента | `[<тип элемента>]` |
  | `set: [<вид>]` | спека элемента; значение — `MapSet` | `MapSet.t(<тип элемента>)` |
  | `map: [key: [<вид>], value: [<вид>]]` | спеки ключа и значения; значение — map | `%{optional(<ключ>) => <значение>}` |
  | `type: :string` | строка | `String.t()` |
  | `type: :boolean` / `:integer` / `:pos_integer` / `:non_neg_integer` / `:map` | примитив | `boolean()` / … |

  `map:` — словарь: вид у ключа и у значения свой; `type: :map` — map без спеки ключа и значения
  (`map()`). Ключ словаря — вид с wire-строкой, как у Codec-плагина по полям: Prim со строковой базой,
  `enum:` или `type: :string`, и не Prim `personal: true` / `sensitive:` (ADR-0091).

  `optional: true` допускает `nil` в значении поля: к типу добавляется `| nil`. Обязательность ключа
  задаёт только `default:` — значение поля по умолчанию: пока его нет, каждая сборка `%Rename{}`
  указывает ключ явно, и новое поле роняет сборку каждого литерала, а не даёт тихий `nil`.

  | `optional:` | `default:` | Ключ в `%Rename{}` | В `@type t` |
  |---|---|---|---|
  | — | — | обязателен | `T` |
  | `true` | — | обязателен | `T \\| nil` |
  | — | значение | можно не указывать | `T` |
  | `true` | `nil` или значение | можно не указывать | `T \\| nil` |

  `personal: true` делает значение ПДн-местом — на нём шифруется всё значение: поле, элемент `list:`
  или значение `map:` целиком, без спуска внутрь. ПДн-местом становится и каждое место с Prim
  `personal: true`; `personal: false` такого не отменяет. `set:` и ключ `map:`, где лист ПДн,
  поднимают границу: шифруется весь `set:`/`map:`. `subject:` — субъект ПДн (по умолчанию
  `:aggregate_id`); адресацию разрешает и проверяет нагрузка события.

  Структура порождает два типа:

  | Тип | Что допускает | Где |
  |---|---|---|
  | `t()` | чтение: на каждом ПДн-месте ещё `Core.Es.Personal.Destroyed.t()` | свёртка, после уничтожения ключа (ADR-0092) |
  | `write_t()` | запись: без `Destroyed.t()`; `entity:` ссылается на `write_t()` сущности | команды и другие входы записи |

  Место — путь от поля: поле с `personal: true`, элемент `list:` или значение `map:`.

  | Спека | `t()` | `write_t()` |
  |---|---|---|
  | `[prim: Mod, personal: true]` | `Mod.t() \| Destroyed.t()` | `Mod.t()` |
  | `[prim: Mod, optional: true, personal: true]` | `Mod.t() \| Destroyed.t() \| nil` | `Mod.t() \| nil` |
  | `[list: [prim: Mod, personal: true]]` | `[Mod.t() \| Destroyed.t()]` | `[Mod.t()]` |
  | `[map: [key: [<вид>], value: [prim: Mod, personal: true]]]` | `%{optional(K) => Mod.t() \| Destroyed.t()}` | `%{optional(K) => Mod.t()}` |

  Без ПДн-мест `@type write_t :: t()`: тип не дублируется. `Inspect` структуры скрывает каждое
  ПДн-место плейсхолдером `%Core.Es.Personal.Hidden{}`, а не всё поле: открытые поля и открытые
  элементы того же списка видны. `%Destroyed{}` печатается обычным struct'ом.

  `default:` — одно типизированное доменное значение поля, оно же значение `defstruct`. Значение,
  в котором есть Prim `personal: true` или `sensitive:`, в исходник не попадает — `CompileError`;
  у `optional: true` допустим `default: nil`.

  `events: Family` — опция `use` state-stored агрегата: модуль семейства событий
  (`use Core.Es.Event.Family`), литерал, проверяется при раскрытии. Порождает поле накопленных
  событий `events` с типом `Core.Es.Events.t(Family.t())` и значением по умолчанию
  `Es.Events.new()`: ключ в `%Role{}` можно не указывать, новый агрегат начинает с пустой
  коллекции. В спеку полей оно не входит: плагин по полям его не видит, подписи
  (`use Core.Labels.Fields`) — тоже: решение о нём не объявляется, подпись на нём — `CompileError`.
  Семейство с кодеком событий сверяет `Core.Repo.Pg.StateStored` (ADR-0092).

      defmodule Role do
        use Core.Struct,
          fields: [
            id: [prim: Role.ID],
            version: [prim: Core.Version],
            name: [prim: Role.Name]
          ],
          events: Role.Event
      end

      %Role{id: id, version: version, name: name}

  `default:` — опция-выражение внутри литерального `fields:` (`docs/rules/20-agreements.md`,
  «Опции `use`»): литерал, вызов чистой функции Prim (`Currency.new!("RUB")`,
  `DeliveryID.from_number!(42)`) или атрибут модуля, объявленный выше `use` (`@rub`). Выражение
  вычисляется в теле модуля, и сборка проверяет вид результата: `prim:` — struct этого Prim, `enum:` —
  значение Enum, `type:` — значение типа, `entity:` — struct модуля, `union:` — struct, но не Prim
  (принадлежность семейству не проверяется: варианты объявляет кодек), `list:` — список,
  поэлементно, `set:` — `MapSet` (`MapSet.new()`, `MapSet.new([@admin])`), поэлементно, `map:` — map
  (`%{}`), по ключу и значению; `nil` — только при `optional: true`.

  > #### Значение вычисляется один раз {: .warning}
  >
  > `default:` вычисляется при сборке модуля, и все struct получают это одно значение.
  > `default: CreatedAt.now!()` или `default: ID.generate()` собираются, но дают момент и
  > идентификатор сборки, а не создания struct, — это ошибка; сборка её не ловит.

  Порождаются в месте `use`:

  - `@enforce_keys` — поля без `default:`;
  - `defstruct` — значения по умолчанию, у поля без `default:` — `nil`;
  - `@type t` — тип чтения по видам полей, `@type write_t` — тип записи, с `events:` — и поле
    `events`;
  - `Inspect` — только если у структуры есть ПДн-места: скрывает их, остальное печатает как обычно;
  - `__struct_fields__/0` — внутренняя для builder'ов ролей: нормализованные поля спеки, форма — не
    контракт; у собранного модуля её читает `Core.Codec.Field.struct_fields/1`;
  - `__core_fields__/0` — внутренняя: тот же состав полей единым IR (`Core.Field`), форма — не
    контракт; у собранного модуля её читает `Core.Field.introspect/1`;
  - `__struct_events__/0` — только с `events:`, внутренняя: семейство событий; у собранного модуля
    её читает `Core.Struct.events_family/1` — роли `Core.Repo.Pg.StateStored`, `Core.Es.Aggregate`
    и `Core.Es.Cmd`.

  Макрос занимает в модуле имена `@core_struct_fields` и `@core_struct_events`: поля спеки
  структуры, которая ещё собирается, отдаёт `declared_fields/1` — по нему `use Core.Labels.Fields`
  ниже берёт вид полей, и подписям хватает `labels:`.

  `fields:`, кроме значений `default:`, — литерал (`docs/rules/20-agreements.md`, «Опции `use`»):
  атрибут или вызов функции — `CompileError` «ожидается литерал». Модули спеки проверяются в теле
  модуля, поэтому MAY быть вложены в него выше `use`.

  `CompileError` с префиксом `Struct: fields: <поле>: …`:

  - `destroyable:` — удалён: ПДн-место объявляет `personal: true`, а `Destroyed.t()` даёт тип чтения;
  - `default:` не того вида, `default: nil` без `optional: true`;
  - `default:`, в значении которого есть Prim `personal: true` или `sensitive:`, в том числе внутри
    struct и списка, — значение ушло бы в исходник и байткод (`default: nil` у такого поля допустим);
  - `prim:` не Prim, `enum:` не `Core.Enum`, `entity:` не struct, `union:` — struct или `Core.Enum`;
  - ключ `map:` без wire-строки или Prim `personal: true` / `sensitive:` ключом, `map:` без `key:` /
    `value:` или с лишним ключом;
  - `personal:` не boolean;
  - несобранный модуль, неизвестное значение `type:`, неизвестный ключ, не ровно один вид;
  - повтор поля;
  - поле `events` рядом с `events:` — его порождает опция.

  `wire:` структуры расходится с wire-ключом Codec-плагина — `CompileError` плагина: ключ объявляет
  структура.

  `events:` не модуль семейства событий или не литерал — `CompileError` с префиксом
  `Struct: events: …`.
  """

  alias Core.Codec.Field
  alias Core.Helper
  alias Core.Helper.FieldCheck
  alias Core.Prim

  @label "Struct"
  @required_keys ~w(fields)a
  @optional_keys ~w(events)a
  @expression_keys [fields: ~w(default)a]

  # ===== декларация =====

  @doc "Объявить структуру по полям (`fields:`)."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)
    family = events!(opts)
    {fields, defaults} = split_defaults(Keyword.fetch!(opts, :fields))
    reject_events_field!(fields, family)

    [
      quote do
        {legacy, personal} = Core.Struct.fields!(unquote(Macro.escape(fields)))
        @core_struct_fields Core.Struct.default!(legacy, unquote(defaults))
        @core_struct_events unquote(family)
        @core_fields Core.Field.normalize!(@core_struct_fields, :struct, "Struct: fields")
        @core_fields Core.Field.apply_personal!(@core_fields, personal)
        @core_inspect_places Core.Field.inspect_places(@core_fields)
      end,
      events_ast(family),
      quote unquote: false do
        @enforce_keys for %Core.Codec.Field{name: name, default: :none} <- @core_struct_fields, do: name
        defstruct Enum.map(@core_struct_fields, fn
                    %Core.Codec.Field{name: name, default: {:default, value}} -> {name, value}
                    %Core.Codec.Field{name: name, default: :none} -> {name, nil}
                  end) ++ Core.Struct.events_entries(@core_struct_events)

        @doc false
        @spec __struct_fields__() :: [Core.Codec.Field.t()]

        def __struct_fields__, do: @core_struct_fields

        @before_compile Core.Struct

        @doc false
        @spec __core_fields__() :: [Core.Field.t()]

        def __core_fields__, do: @core_fields
      end,
      types_ast()
    ]
  end

  # ---

  # Команда — вход записи: её `t` уже проекция записи, даже если поле — персональный Prim
  # (`use Core.Es.Cmd` помечает модуль атрибутом `@core_command`). Пометку читает тело модуля, а не
  # раскрытие макроса: тело раскрывается целиком до исполнения, и атрибут выше `use` ещё не стоит.
  defp types_ast do
    quote unquote: false do
      if Module.get_attribute(__MODULE__, :core_command) == true do
        @type t :: unquote(Core.Struct.write_type(@core_fields, @core_struct_events))
        @type write_t :: t()
      else
        @type t :: unquote(Core.Struct.read_type(@core_fields, @core_struct_events))
        @type write_t :: unquote(Core.Struct.write_type(@core_fields, @core_struct_events))
      end
    end
  end

  defp events!(opts) do
    case Keyword.fetch(opts, :events) do
      :error -> nil
      {:ok, _family} -> family!(Helper.Opts.module!(opts, :events, @label))
    end
  end

  defp family!(module) do
    if Helper.Module.exports?(module, :__es_codec__, 0),
      do: module,
      else:
        Helper.Opts.reject!(
          "#{@label}: events",
          "ожидается семейство событий (use Core.Es.Event.Family), получено #{inspect(module)}"
        )
  end

  defp reject_events_field!(fields, family) do
    if family && Keyword.keyword?(fields) && Keyword.has_key?(fields, :events) do
      Helper.Opts.reject!(
        "#{@label}: fields: events",
        "поле events порождает events: #{inspect(family)} — в fields: оно не объявляется"
      )
    end
  end

  defp events_ast(nil), do: nil

  defp events_ast(family) do
    quote do
      @doc false
      @spec __struct_events__() :: module()

      def __struct_events__, do: unquote(family)
    end
  end

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

  # ===== Inspect =====

  @doc false
  defmacro __before_compile__(env) do
    case Module.get_attribute(env.module, :core_inspect_places) do
      places when is_map(places) and map_size(places) > 0 ->
        places = Macro.escape(places)

        quote do
          defimpl Inspect, for: unquote(env.module) do
            def inspect(struct, opts), do: Core.Struct.inspect_struct(struct, unquote(places), opts)
          end
        end

      _places ->
        nil
    end
  end

  # ---

  @doc false
  @spec inspect_struct(struct(), map(), Inspect.Opts.t()) :: term()

  def inspect_struct(%module{} = struct, places, opts) when is_map(places) do
    values =
      Enum.reduce(places, Map.from_struct(struct), fn {name, paths}, acc ->
        Map.update!(acc, name, &Core.Field.hide_personal(&1, paths))
      end)

    infos = for %{field: field} = info <- module.__info__(:struct) || [], field != :__exception__, do: info
    Inspect.Map.inspect_as_struct(values, Macro.inspect_atom(:literal, module), infos, opts)
  end

  # ===== типы =====

  @doc false
  @spec read_type([Field.t()], module() | nil) :: Macro.t()

  def read_type(fields, events) do
    entries = Core.Field.read_typespec(fields) ++ events_typespec(events)

    quote do
      %__MODULE__{unquote_splicing(entries)}
    end
  end

  @doc false
  @spec write_type([Field.t()], module() | nil) :: Macro.t()

  def write_type(fields, events) do
    if Core.Field.personal_places?(fields) do
      entries = Core.Field.write_typespec(fields) ++ events_typespec(events)

      quote do
        %__MODULE__{unquote_splicing(entries)}
      end
    else
      quote(do: t())
    end
  end

  # ===== events: =====

  @doc false
  @spec events_entries(module() | nil) :: keyword()

  def events_entries(nil), do: []
  def events_entries(family) when is_atom(family), do: [events: Core.Es.Events.new()]

  @doc false
  @spec events_typespec(module() | nil) :: keyword(Macro.t())

  def events_typespec(nil), do: []
  def events_typespec(family) when is_atom(family), do: [events: quote(do: Core.Es.Events.t(unquote(family).t()))]

  @doc false
  @spec events_family(module()) :: module() | nil

  def events_family(module) when is_atom(module),
    do: if(Helper.Module.exports?(module, :__struct_events__, 0), do: module.__struct_events__())

  # Роль, чей модуль полем событий не владеет, отказывает `events:` на `@after_compile`.
  @doc false
  @spec reject_events!(Macro.Env.t(), String.t(), String.t()) :: :ok

  def reject_events!(%Macro.Env{module: module} = env, label, text) when is_binary(label) and is_binary(text) do
    if events_family(module) do
      raise CompileError,
        description: "#{label}: #{inspect(module)}: events: #{text}",
        file: env.file,
        line: env.line
    end

    :ok
  end

  # ===== поля =====

  @doc false
  @spec declared_fields(module()) :: [Field.t()] | nil

  def declared_fields(module) when is_atom(module), do: Module.get_attribute(module, :core_struct_fields)

  @doc false
  @spec fields!(term()) :: {[Field.t()], %{{atom(), [atom()]} => boolean()}}

  def fields!(spec) do
    where = "#{@label}: fields"
    check_unique!(spec, where)

    Core.Field.split!(spec, :struct, where)
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

  defp check_value!({:set, inner}, %MapSet{} = values, where),
    do: Enum.each(values, &check_value!(inner, &1, where))

  defp check_value!({:set, _inner}, value, where), do: mismatch!(where, "MapSet", value)

  defp check_value!({:map, key, inner}, values, where) when is_map(values) and not is_struct(values) do
    Enum.each(values, fn {k, v} ->
      check_value!(key, k, where)
      check_value!(inner, v, where)
    end)
  end

  defp check_value!({:map, _key, _inner}, value, where), do: mismatch!(where, "map", value)

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
