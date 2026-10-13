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

  У struct'а без спеки полей — нагрузки с ручным плагином кодека, вложенного struct'а сведений,
  варианта семейства — вид видимых полей задаёт `fields:` на языке спеки плагина по полям
  (`Core.Codec.Plugin.Fields`), её разбирает тот же нормализатор:

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

  Полнота проверяется на `@after_compile`, где уже есть struct и спека нагрузки. Сборку ломают:
  поле без решения, подпись поля, которого нет в struct'е, повтор поля, пустая подпись, подпись у
  свободной map'ы (`type: :map`), вложенный struct (`entity:`) без `use Core.Labels.Fields`; у
  нагрузки — `fields:`; у struct'а без спеки полей — отсутствие `fields:`, видимое поле без спеки,
  спека скрытого поля или поля вне struct'а, `text:` не захватом функции арности 1.

  Макрос занимает в модуле имена `__label_fields__/0` и `__label_specs__/0`.
  """

  alias Core.Codec.Plugin
  alias Core.Labels.Check

  @typedoc "Решение по полю: подпись или скрыто."
  @type label :: String.t() | :hidden

  @typedoc "Спека значения поля: спека плагина по полям или текст функцией (`text:`)."
  @type spec :: Plugin.Fields.spec() | {:text, (term() -> String.t())} | {:list, spec()}

  @typedoc "Путь поля от корня типа."
  @type path :: [atom(), ...]

  @label "Labels.Fields"
  @required_keys ~w(labels)a
  @optional_keys ~w(fields)a

  # ===== объявление =====

  @doc "Объявить решение по каждому полю (`labels:`) и спеку видимых полей struct'а без неё (`fields:`)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Core.Helper.Opts.validate!(
        opts,
        Core.Labels.Fields.required_keys(),
        Core.Labels.Fields.optional_keys(),
        "Labels.Fields"
      )

      @label_specs Core.Labels.Fields.specs!(__MODULE__, Keyword.get(opts, :fields))
      @label_fields Core.Labels.Fields.labels!(__MODULE__, Keyword.fetch!(opts, :labels))
      @after_compile Core.Labels.Fields

      @doc false
      @spec __label_fields__() :: [{atom(), Core.Labels.Fields.label()}]

      def __label_fields__, do: @label_fields

      @doc false
      @spec __label_specs__() :: [{atom(), Core.Labels.Fields.spec()}]

      def __label_specs__, do: @label_specs
    end
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  # Спека нагрузки известна уже при раскрытии `use`: `use Core.Es.Event.Payload` выше положил её в атрибут.
  @doc false
  @spec specs!(module(), term()) :: [{atom(), spec()}]

  def specs!(module, fields) when is_atom(module) do
    case {Module.get_attribute(module, :es_payload_fields), fields} do
      {nil, nil} ->
        raise CompileError,
          description:
            "#{where(module)} — не нагрузка: `use Core.Labels.Fields` подключается после " <>
              "`use Core.Es.Event.Payload` или объявляет спеку видимых полей `fields:`"

      {payload, nil} ->
        pairs(payload)

      {nil, fields} ->
        fields!(module, fields)

      {_payload, fields} ->
        raise CompileError,
          description:
            "#{where(module)}: спека поля и у нагрузки события, и в `fields:` — вид поля нагрузки " <>
              "задаёт её спека: #{inspect(Keyword.keys(fields))}"
    end
  end

  @doc false
  @spec labels!(module(), term()) :: [{atom(), label()}]

  def labels!(module, labels) when is_atom(module) do
    where = "#{where(module)}: labels:"

    for {field, label} <- Check.keyword!(labels, where), do: {field, label!(label, "#{where} поле #{field}")}
  end

  # ---

  defp fields!(module, fields) do
    where = "#{where(module)}: fields:"
    fields = Check.keyword!(fields, where)
    {texts, rest} = Enum.split_with(fields, fn {_name, opts} -> text?(opts) end)
    texts = Map.new(texts, fn {name, opts} -> {name, text_spec!(opts, "#{where}, поле #{name}")} end)
    specs = Map.merge(texts, normalize!(rest, where))

    for {name, _opts} <- fields, do: {name, Map.fetch!(specs, name)}
  end

  defp text?(opts), do: Keyword.keyword?(opts) and (Keyword.has_key?(opts, :text) or text_list?(opts[:list]))

  defp text_list?(inner), do: Keyword.keyword?(inner) and Keyword.has_key?(inner, :text)

  defp text_spec!([text: fun], where), do: {:text, Check.capture!(fun, 1, "#{where}: text:")}

  defp text_spec!([list: [text: fun]], where),
    do: {:list, {:text, Check.capture!(fun, 1, "#{where}: list: text:")}}

  defp text_spec!(opts, where) do
    raise CompileError,
      description:
        "#{where} — `text:` без других ключей: [text: &f/1] или [list: [text: &f/1]], " <>
          "задано #{inspect(opts)}"
  end

  defp normalize!([], _where), do: %{}

  defp normalize!(fields, where), do: Map.new(pairs(Plugin.Fields.normalize!(fields, where)))

  defp pairs(fields), do: for({name, spec, _optional?, _wire, _default} <- fields, do: {name, spec})

  defp label!(:hidden, _where), do: :hidden
  defp label!(text, where), do: Check.text!(text, where)

  # ===== проверка полноты =====

  @doc false
  @spec __after_compile__(Macro.Env.t(), binary()) :: :ok

  def __after_compile__(env, _bytecode) do
    module = env.module
    payload? = Module.defines?(module, {:__es_payload_fields__, 0})

    if not Module.defines?(module, {:__struct__, 0}) do
      fail!(env, "не struct — `fields:` подписывает поля struct'а")
    end

    fields = Map.keys(module.__struct__()) -- [:__struct__]
    labels = module.__label_fields__()
    labelled = Keyword.keys(labels)

    ensure_none!(env, fields -- labelled, "поля без подписи или `:hidden`")
    ensure_none!(env, labelled -- fields, "подписи полей вне struct'а")

    if not payload?, do: ensure_specs!(env, module.__label_specs__(), labels, fields)

    visible = specs(module)
    maps = for {name, spec} <- visible, map?(spec), do: name
    unlabelled = for {name, spec} <- visible, unlabelled?(spec), do: name

    ensure_none!(env, maps, "свободная map подписью не выходит — `:hidden`")
    ensure_none!(env, unlabelled, "вложенный struct без `use Core.Labels.Fields`")
  end

  # ---

  defp ensure_specs!(env, specs, labels, fields) do
    specced = Keyword.keys(specs)
    hidden = for {name, :hidden} <- labels, do: name

    ensure_none!(env, (fields -- hidden) -- specced, "видимые поля без спеки `fields:`")
    ensure_none!(env, Enum.filter(specced, &(&1 in hidden)), "спека скрытых полей")
    ensure_none!(env, specced -- fields, "спека полей вне struct'а")
  end

  defp map?({:type, :map}), do: true
  defp map?({:list, inner}), do: map?(inner)
  defp map?(_spec), do: false

  defp unlabelled?({:entity, mod}), do: not exports?(mod, :__label_fields__)
  defp unlabelled?({:list, inner}), do: unlabelled?(inner)
  defp unlabelled?(_spec), do: false

  # `function_exported?/3` отвечает только про загруженный модуль, а собранный при сборке проекта не загружен.
  defp exports?(mod, fun), do: match?({:module, _}, Code.ensure_compiled(mod)) and function_exported?(mod, fun, 0)

  defp ensure_none!(_env, [], _message), do: :ok
  defp ensure_none!(env, fields, message), do: fail!(env, "#{message}: #{inspect(fields)}")

  defp fail!(env, message) do
    raise CompileError, description: "#{where(env.module)}: #{message}", file: env.file, line: env.line
  end

  # ===== интроспекция =====

  @doc "Спека видимых полей struct'а — в порядке объявления спеки, без `:hidden`."
  @spec specs(module()) :: [{atom(), spec()}]

  def specs(module) when is_atom(module) do
    labels = module.__label_fields__()

    for {name, spec} <- module.__label_specs__(), Keyword.fetch!(labels, name) != :hidden, do: {name, spec}
  end

  @doc """
  Подписи видимых полей типа по пути поля, без значения, — в порядке объявления спеки.

  Поля вложенного struct'а (`entity:`) идут под путём своего поля, поля элемента списка struct'ов —
  под путём списка. Поле `union:` даёт только свою подпись: варианты семейства по типу не известны.
  """
  @spec paths(module()) :: [{path(), String.t()}]

  def paths(module) when is_atom(module) do
    labels = module.__label_fields__()

    Enum.flat_map(specs(module), fn {name, spec} ->
      nested = for {path, label} <- nested_paths(spec), do: {[name | path], label}

      [{[name], Keyword.fetch!(labels, name)} | nested]
    end)
  end

  # ---

  defp nested_paths({:entity, mod}), do: paths(mod)
  defp nested_paths({:list, inner}), do: nested_paths(inner)
  defp nested_paths(_spec), do: []

  # ===== общее =====

  defp where(module), do: "#{@label} #{inspect(module)}"
end
