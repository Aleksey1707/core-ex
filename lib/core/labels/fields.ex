defmodule Core.Labels.Fields do
  @moduledoc """
  Подписи полей struct'а — решение по каждому полю (ADR-0063).

  Подключается в нагрузке `Core.Es.Event.Payload` после её `use`:

      defmodule Payload do
        use Core.Es.Event.Payload,
          fields: [
            name: [prim: MyApp.Domain.Sales.Account.Name],
            limit: [prim: MyApp.Domain.Sales.Account.Limit, optional: true],
            source: [type: :string]
          ]

        use Core.Labels.Fields,
          labels: [
            name: "Название",
            limit: "Лимит",
            source: :hidden
          ]
      end

  Решение по полю — подпись (непустая строка) или `:hidden`: поле в сведения не попадает. Вид поля
  в сведениях (`Core.Labels.Details`) у нагрузки берётся из её спеки, в объявлении подписей его нет.

  Свободная map'а (`type: :map`) с id в ключах подписывается ключом и значением —
  `[label:, key:, value:]` — и выходит в сведения списком групп «ключ — значение»:

      use Core.Labels.Fields,
        labels: [
          limits: [label: "Лимиты", key: "Счёт", value: "Лимит"]
        ]

  У struct'а без спеки полей — нагрузки с ручным плагином кодека, вложенного struct'а сведений,
  варианта семейства — вид видимых полей задаёт `fields:` на языке спеки плагина по полям
  (`Core.Codec.Field`), её разбирает тот же нормализатор:

      defmodule MyApp.Domain.Sales.Account.Address do
        defstruct [:city, :origin, :tags, :checksum]

        use Core.Labels.Fields,
          fields: [
            city: [prim: MyApp.Domain.Sales.Account.City],
            origin: [text: &MyApp.Domain.Sales.Account.Address.origin_text/1],
            tags: [list: [text: &Atom.to_string/1]]
          ],
          labels: [
            city: "Город",
            origin: "Источник",
            tags: "Метки",
            checksum: :hidden
          ]
      end

  Сверх языка плагина — вид `text:`: захват функции арности 1, значение выходит текстом её
  результата; так подписывается значение без собственного модуля. `text:` и `list: [text: …]` — без
  других ключей.

  `fields:` и `value:` — опции-выражения (`docs/rules/20-agreements.md`, «Опции `use`»): захваты в
  них проверяются в теле модуля; `labels:` и `change:` — литералы, проверяются при раскрытии `use`.

  Полнота проверяется на `@after_compile`, где уже есть struct и спека нагрузки. Сборку ломают:
  поле без решения, подпись поля, которого нет в struct'е, повтор поля, пустая подпись, свободная
  map'а (`type: :map`) с подписью строкой, видимый список map'ов (`list: [type: :map]`, решение у него
  только `:hidden`), подписи map'ы у поля, которое не map'а, ключ подписи map'ы вне
  `[label:, key:, value:]`, вложенный struct (`entity:`) без `use Core.Labels.Fields`; у нагрузки —
  `fields:`; у struct'а без спеки полей — отсутствие `fields:`, видимое поле без спеки, спека скрытого
  поля или поля вне struct'а, `text:` не захватом функции арности 1.

  Нагрузка «было → стало» объявляет вместо `labels:` одну подпись изменения `change:` — ровно одна из
  двух опций. Вид значения у `Core.Es.ValueChanged` берётся из его `type:`, у ручного struct'а с
  полями `old_value` / `new_value` — из `value:`, спеки одного значения на языке `fields:`:

      defmodule Payload do
        use Core.Es.ValueChanged,
          type: MyApp.Domain.Sales.Account.Name

        use Core.Labels.Fields, change: "Название"
      end

      defmodule MyApp.Domain.Sales.Account.TagsChanged do
        defstruct [:old_value, :new_value]

        use Core.Labels.Fields,
          change: "Метки",
          value: [list: [text: &Atom.to_string/1]]
      end

  Сборку ломают: `labels:` или `fields:` вместе с `change:`, ручной struct изменения без `value:`,
  `value:` у `Core.Es.ValueChanged` или без `change:`, struct без `old_value` / `new_value` или с
  полями вне них под `change:`, `use` под `change:` не после `use Core.Es.ValueChanged` или
  `defstruct`, значение изменения — map'а или список map'ов на любой глубине `list:` (в сведения
  оно не выходит, и подписать его нельзя).

  Макрос занимает в модуле имена `__label_fields__/0`, `__label_specs__/0` и `__label_change__/0`.
  """

  alias Core.Codec.Field
  alias Core.Es.Event.Payload
  alias Core.Es.ValueChanged
  alias Core.Helper
  alias Core.Labels.Check

  @typedoc "Решение по полю: подпись, подписи map'ы с id в ключах или скрыто."
  @type label :: String.t() | map_label() | :hidden

  @typedoc "Подписи map'ы с id в ключах: поля, ключа и значения."
  @type map_label :: [label: String.t(), key: String.t(), value: String.t()]

  @typedoc "Спека значения поля: спека плагина по полям или текст функцией (`text:`)."
  @type spec :: Field.spec() | {:text, (term() -> String.t())} | {:list, spec()}

  # Объявление модуля под `use`: поля нагрузки (`Core.Es.Event.Payload`), вид значения изменения
  # (`Core.Es.ValueChanged`), struct без них или ничего.
  @typedoc false
  @type host :: {:payload, [Field.t()]} | {:change, [type: module(), nilable: boolean()]} | :struct | :none

  @typedoc false
  @type declared :: %{specs: [{atom(), spec()}], fields: [{atom(), label()}], change: {String.t(), spec()} | nil}

  @typedoc "Путь поля от корня типа."
  @type path :: [atom(), ...]

  @label "Labels.Fields"
  @required_keys []
  @optional_keys ~w(labels change fields value)a
  @expression_keys ~w(fields value)a
  @map_keys ~w(label key value)a
  @change_fields ~w(old_value new_value)a

  # ===== объявление =====

  @doc """
  Объявить решение по каждому полю (`labels:`) и спеку видимых полей struct'а без неё (`fields:`) либо
  подпись изменения (`change:`) и вид его значения у ручного struct'а (`value:`).
  """
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)

    decision = decision!(opts)

    spec =
      case decision do
        {:labels, _labels} -> quote(do: Core.Labels.Fields.fields!(unquote(opts[:fields])))
        {:change, _label} -> quote(do: Core.Labels.Fields.value!(unquote(opts[:value])))
      end

    quote do
      declared =
        Core.Labels.Fields.declare!(
          Core.Labels.Fields.host(__MODULE__),
          unquote(Macro.escape(decision)),
          unquote(spec)
        )

      @label_specs declared.specs
      @label_fields declared.fields
      @label_change declared.change
      @after_compile Core.Labels.Fields

      @doc false
      @spec __label_fields__() :: [{atom(), Core.Labels.Fields.label()}]

      def __label_fields__, do: @label_fields

      @doc false
      @spec __label_specs__() :: [{atom(), Core.Labels.Fields.spec()}]

      def __label_specs__, do: @label_specs

      @doc false
      @spec __label_change__() :: {String.t(), Core.Labels.Fields.spec()} | nil

      def __label_change__, do: @label_change
    end
  end

  # ---

  defp decision!(opts) do
    case {Keyword.fetch(opts, :labels), Keyword.fetch(opts, :change)} do
      {{:ok, labels}, :error} ->
        if Keyword.has_key?(opts, :value),
          do: Helper.Opts.reject!("#{@label}: value", "без `change:` — вид значения задаёт изменение")

        {:labels, labels!(labels)}

      {:error, {:ok, label}} ->
        if Keyword.has_key?(opts, :fields),
          do: Helper.Opts.reject!("#{@label}: fields", "вместе с `change:` — вид значения изменения задаёт `value:`")

        {:change, Check.text!(label, "#{@label}: change")}

      {:error, :error} ->
        Helper.Opts.reject!(@label, "ожидается одна из опций `labels:` / `change:`, получено ни одной")

      {{:ok, _labels}, {:ok, _label}} ->
        Helper.Opts.reject!(@label, "ожидается одна из опций `labels:` / `change:`, получено обе")
    end
  end

  defp labels!(labels) do
    where = "#{@label}: labels"

    for {field, label} <- Check.keyword!(labels, where), do: {field, label!(label, "#{where}: #{field}")}
  end

  defp label!(:hidden, _where), do: :hidden

  defp label!([_ | _] = map, where) do
    Helper.Opts.validate!(map, @map_keys, [], where)

    for key <- @map_keys, do: {key, Check.text!(Keyword.fetch!(map, key), "#{where}: #{key}")}
  end

  defp label!(text, where), do: Check.text!(text, where)

  # ===== выражения в теле =====

  @doc false
  @spec fields!(term()) :: [{atom(), spec()}] | nil

  def fields!(nil), do: nil

  def fields!(fields) do
    where = "#{@label}: fields"

    parse!(Check.keyword!(fields, where), where)
  end

  @doc false
  @spec value!(term()) :: spec() | nil

  def value!(nil), do: nil

  def value!(value) do
    where = "#{@label}: value"

    if text?(value), do: text_spec!(value, where), else: normalize!([value: value], @label).value
  end

  # ---

  defp parse!(fields, where) do
    {texts, rest} = Enum.split_with(fields, fn {_name, opts} -> text?(opts) end)
    texts = Map.new(texts, fn {name, opts} -> {name, text_spec!(opts, "#{where}: #{name}")} end)
    specs = Map.merge(texts, normalize!(rest, where))

    for {name, _opts} <- fields, do: {name, Map.fetch!(specs, name)}
  end

  defp text?(opts), do: Keyword.keyword?(opts) and (Keyword.has_key?(opts, :text) or text_list?(opts[:list]))

  defp text_list?(inner), do: Keyword.keyword?(inner) and Keyword.has_key?(inner, :text)

  defp text_spec!([text: fun], where), do: {:text, Check.capture!(fun, 1, "#{where}: text")}

  defp text_spec!([list: [text: fun]], where),
    do: {:list, {:text, Check.capture!(fun, 1, "#{where}: list: text")}}

  defp text_spec!(opts, where) do
    Helper.Opts.reject!(
      where,
      "`text:` без других ключей: [text: &f/1] или [list: [text: &f/1]], получено #{inspect(opts)}"
    )
  end

  defp normalize!([], _where), do: %{}
  defp normalize!(fields, where), do: Map.new(pairs(Field.normalize!(fields, :labels, where)))

  # ===== решение по объявлению модуля =====

  # Объявление модуля известно только телу: `use Core.Es.Event.Payload` или `use Core.Es.ValueChanged`
  # выше пишет его атрибутом. Struct нужен уже здесь: без него `use` выше `use Core.Es.ValueChanged`
  # сошёл бы за ручной struct.
  @doc false
  @spec host(module()) :: host()

  def host(module) when is_atom(module) do
    case {Payload.declared_fields(module), ValueChanged.declared(module)} do
      {nil, nil} -> if Module.defines?(module, {:__struct__, 0}), do: :struct, else: :none
      {nil, changed} -> {:change, changed}
      {fields, nil} -> {:payload, fields}
    end
  end

  @doc false
  @spec declare!(host(), {:labels, [{atom(), label()}]} | {:change, String.t()}, [{atom(), spec()}] | spec() | nil) ::
          declared()

  def declare!(host, {:labels, labels}, specs),
    do: %{specs: specs!(host, specs), fields: labels, change: nil}

  def declare!(host, {:change, label}, value), do: %{specs: [], fields: [], change: change!(host, label, value)}

  # ---

  defp specs!({:payload, payload}, nil), do: pairs(payload)

  defp specs!({:payload, _payload}, specs) do
    Helper.Opts.reject!(
      "#{@label}: fields",
      "спека поля и у нагрузки события — вид поля нагрузки задаёт её спека: #{inspect(Keyword.keys(specs))}"
    )
  end

  defp specs!(_host, nil) do
    Helper.Opts.reject!(
      @label,
      "не нагрузка: `use Core.Labels.Fields` подключается после `use Core.Es.Event.Payload` " <>
        "или объявляет спеку видимых полей `fields:`"
    )
  end

  defp specs!(_host, specs), do: specs

  defp change!(:none, _label, _value) do
    Helper.Opts.reject!(
      @label,
      "`use Core.Labels.Fields, change:` подключается после `use Core.Es.ValueChanged` или `defstruct`"
    )
  end

  defp change!({:change, changed}, label, nil),
    do: {label, Field.value_spec(Keyword.fetch!(changed, :type), "#{@label}: change")}

  defp change!({:change, _changed}, _label, _value),
    do: Helper.Opts.reject!(@label, "`value:` у `Core.Es.ValueChanged` — вид значения задаёт его `type:`")

  defp change!(_struct, _label, nil),
    do: Helper.Opts.reject!(@label, "ручной struct изменения без `value:` — вид значения на языке спеки `fields:`")

  defp change!(_struct, label, value), do: {label, value}

  # ===== проверка полноты =====

  @doc false
  @spec __after_compile__(Macro.Env.t(), binary()) :: :ok

  def __after_compile__(env, _bytecode) do
    module = env.module

    if not Module.defines?(module, {:__struct__, 0}) do
      fail!(env, "не struct — `fields:` подписывает поля struct'а")
    end

    fields = Map.keys(module.__struct__()) -- [:__struct__]

    case change(module) do
      nil -> ensure_labels!(env, fields)
      {_label, spec} -> ensure_change!(env, fields, spec)
    end

    visible = visible(module)
    labelled_maps = for {name, [_ | _]} <- labels(module), do: name
    not_maps = for {name, spec} <- visible, name in labelled_maps, not map?(spec), do: name
    maps = for {name, {:type, :map}} <- visible, name not in labelled_maps, do: name
    map_lists = for {name, {:list, inner}} <- visible, map?(inner), do: name
    unlabelled = for {name, spec} <- visible, unlabelled?(spec), do: name

    ensure_none!(env, not_maps, "подписи map'ы `[label:, key:, value:]` у поля, которое не map'а")

    ensure_none!(
      env,
      maps,
      "свободная map'а выходит подписями ключа и значения — `[label:, key:, value:]` или `:hidden`"
    )

    ensure_none!(env, map_lists, "список map'ов в сведения не выходит — только `:hidden`")

    ensure_none!(env, unlabelled, "вложенный struct без `use Core.Labels.Fields`")
  end

  # ---

  defp ensure_labels!(env, fields) do
    module = env.module
    labels = labels(module)
    labelled = Keyword.keys(labels)

    ensure_none!(env, fields -- labelled, "поля без подписи или `:hidden`")
    ensure_none!(env, labelled -- fields, "подписи полей вне struct'а")

    if is_nil(Payload.declared_fields(module)),
      do: ensure_specs!(env, module.__label_specs__(), labels, fields)
  end

  defp ensure_specs!(env, specs, labels, fields) do
    specced = Keyword.keys(specs)
    hidden = for {name, :hidden} <- labels, do: name

    ensure_none!(env, (fields -- hidden) -- specced, "видимые поля без спеки `fields:`")
    ensure_none!(env, Enum.filter(specced, &(&1 in hidden)), "спека скрытых полей")
    ensure_none!(env, specced -- fields, "спека полей вне struct'а")
  end

  defp ensure_change!(env, fields, spec) do
    ensure_none!(env, @change_fields -- fields, "struct изменения без полей")
    ensure_none!(env, fields -- @change_fields, "поля struct'а изменения вне `old_value` / `new_value`")

    if map?(spec),
      do: fail!(env, "значение изменения — map'а или список map'ов: в сведения не выходит, подписать его нельзя")
  end

  defp map?({:type, :map}), do: true
  defp map?({:list, inner}), do: map?(inner)
  defp map?(_spec), do: false

  defp unlabelled?({:entity, mod}), do: not labelled?(mod)
  defp unlabelled?({:list, inner}), do: unlabelled?(inner)
  defp unlabelled?(_spec), do: false

  defp ensure_none!(_env, [], _message), do: :ok
  defp ensure_none!(env, fields, message), do: fail!(env, "#{message}: #{inspect(fields)}")

  defp fail!(env, message) do
    raise CompileError, description: "#{@label} #{inspect(env.module)}: #{message}", file: env.file, line: env.line
  end

  # ===== интроспекция =====

  @doc "Подпись и вид значения изменения (`change:`); у struct'а с подписями полей — `nil`."
  @spec change(module()) :: {String.t(), spec()} | nil

  def change(module) when is_atom(module), do: module.__label_change__()

  @doc "Спека видимых полей struct'а — в порядке объявления спеки, без `:hidden`; у изменения — пусто."
  @spec specs(module()) :: [{atom(), spec()}]

  def specs(module) when is_atom(module) do
    labels = labels(module)

    for {name, spec} <- module.__label_specs__(), Keyword.fetch!(labels, name) != :hidden, do: {name, spec}
  end

  @doc """
  Struct объявляет решение по полям (`use Core.Labels.Fields`). Модуль, ещё не загруженный, грузится или
  собирается — ответ верен и при сборке, и в рантайме.
  """
  @spec labelled?(module()) :: boolean()

  def labelled?(module) when is_atom(module) do
    Core.Helper.Module.exports?(module, :__label_fields__, 0)
  end

  @doc "Решение по каждому полю — в порядке объявления `labels:`; у изменения — пусто."
  @spec labels(module()) :: [{atom(), label()}]

  def labels(module) when is_atom(module), do: module.__label_fields__()

  @doc """
  Видимые поля struct'а со спекой значения — в порядке спеки, без `:hidden`; у struct'а изменения —
  `old_value` / `new_value` со спекой значения `change:`.
  """
  @spec visible(module()) :: [{atom(), spec()}]

  def visible(module) when is_atom(module) do
    case change(module) do
      nil -> specs(module)
      {_label, spec} -> [old_value: spec, new_value: spec]
    end
  end

  @doc """
  Подписи видимых полей типа по пути поля, без значения, — в порядке объявления спеки.

  Поля вложенного struct'а (`entity:`) идут под путём своего поля, поля элемента списка struct'ов —
  под путём списка. Поле `union:` даёт только свою подпись: варианты семейства по типу не известны;
  map'а с id в ключах — подпись поля (`label:`).
  """
  @spec paths(module()) :: [{path(), String.t()}]

  def paths(module) when is_atom(module) do
    labels = labels(module)

    Enum.flat_map(specs(module), fn {name, spec} ->
      nested = for {path, label} <- nested_paths(spec), do: {[name | path], label}

      [{[name], text(Keyword.fetch!(labels, name))} | nested]
    end)
  end

  # ---

  defp nested_paths({:entity, mod}), do: paths(mod)
  defp nested_paths({:list, inner}), do: nested_paths(inner)
  defp nested_paths(_spec), do: []

  defp text(label: label, key: _key, value: _value), do: label
  defp text(label), do: label

  # ===== общее =====

  defp pairs(fields), do: for(%Field{name: name, spec: spec} <- fields, do: {name, spec})
end
