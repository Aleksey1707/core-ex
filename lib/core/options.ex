defmodule Core.Options do
  @moduledoc """
  Схема опций функции: `use Core.Options` и атрибут `@opts_schema` над `def` (ADR-0086,
  `docs/rules/20-agreements.md`, «Схема опций функции»).

      defmodule MyApp.Report do
        use Core.Options

        @opts_schema [
          batch_size: [type: :pos_integer, default: 100, doc: "Сколько строк читает пачка."]
        ]
        @spec build(module(), keyword()) :: Core.Result.unit()

        def build(source, opts \\\\ []) when is_atom(source) and is_list(opts) do
          batch_size = Keyword.fetch!(opts, :batch_size)
          ...
        end
      end

  `@opts_schema` — схема NimbleOptions; у каждого ключа обязателен `doc:` строкой. Вызов с ключом
  вне схемы или значением не того типа — `ArgumentError` с текстом
  `"<Mod.fun/n>: <сообщение NimbleOptions>"` до входа в тело. В тело приходят проверенные опции,
  дополненные умолчаниями; вызов с `[]` NimbleOptions не проходит — умолчания вычислены при сборке.
  Схема без обязательных ключей проверяет свои умолчания при сборке, поэтому `{:custom, mod, fun,
  args}` в ней ссылается на модуль, собранный раньше вызывающего.

  ## Подмена `def`

  `use Core.Options` исключает `Kernel.def/1,2` из импорта и импортирует `def/1,2` отсюда. Голова
  клаузы не меняется: паттерны и guards прочих аргументов, домен функции для вывода типов и кадр
  стека остаются авторскими. Тело клаузы оборачивается маркером, который раскрывается вместе с
  телом, когда определение сохраняется: в этот момент атрибут над функцией уже вычислен.

  - Атрибута нет — тело остаётся как есть.
  - Атрибут есть — первым выражением тела последний аргумент перепривязывается проверенным
    значением.

  Схема относится к функции (имя и арность): атрибут ставится перед первой клаузой и действует на
  все её клаузы, следующей функции он не достаётся. Голова без тела (`def f(a, opts \\\\ [])`) уходит
  в `Kernel.def`, а схема над ней объявляется на голове; проверяется полная арность. Неявный `try`
  клаузы (`rescue` / `catch` / `after` / `else` у `def`) проверку не охватывает: отказ вызова не
  ловится телом функции.

  ## Документация

  `@doc` функции со схемой дописывается разделом «Опции» — ключ, тип, умолчание и `doc:` каждого
  (`NimbleOptions.docs/1`) — после текста автора. Функция без `@doc` получает `@doc` из одного
  раздела. При `@doc false` и у `@impl` без `@doc` раздел не дописывается: функция остаётся скрытой.
  Описание опций для `@moduledoc` (OTP-процесс со схемой над `init/1`) — `docs/1`.

  ## Ошибки объявления

  `CompileError` (`Core.Helper.Opts.reject!/2`, метка `Options`):

  - схема не keyword или некорректна для NimbleOptions; ключ схемы без `doc:` строкой; умолчание
    не проходит свою схему;
  - `@opts_schema` над `defp` / `defmacro` / `defmacrop` или над `def`, который раскрыт не здесь
    (`defdelegate`, `Kernel.def`);
  - `@opts_schema` перед второй и следующей клаузой функции или между головой без тела и первой
    клаузой;
  - висячий `@opts_schema` — за ним нет `def` до конца модуля;
  - последний аргумент функции со схемой — не переменная или на него стоит guard, кроме
    `is_list/1`.

  Модуль занимает в вызывающем атрибуты `@opts_schema` и `@core_options_schemas`.
  """

  alias Core.Helper

  @label "Options"
  @required_keys ~w()a
  @optional_keys ~w()a
  @expression_keys ~w()a

  # ===== подключение =====

  @doc "Подключить схему опций к `def` модуля."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    Helper.Opts.literal!(opts, @expression_keys, @label)

    quote do
      import Kernel, except: [def: 1, def: 2]
      import Core.Options, only: [def: 1, def: 2]

      Module.register_attribute(__MODULE__, :opts_schema, [])
      @on_definition Core.Options
      @before_compile Core.Options
    end
  end

  @doc false
  @spec __on_definition__(Macro.Env.t(), atom(), atom(), [Macro.t()], [Macro.t()], Macro.t()) :: :ok

  def __on_definition__(%Macro.Env{module: module}, kind, name, args, _guards, body) do
    if body != nil and Module.get_attribute(module, :opts_schema) != nil,
      do: Helper.Opts.reject!("#{@label}: #{name}/#{length(args)}", misplaced(kind))

    :ok
  end

  @doc false
  defmacro __before_compile__(%Macro.Env{module: module}) do
    if Module.get_attribute(module, :opts_schema) != nil,
      do: Helper.Opts.reject!("#{@label}: @opts_schema", "висячий атрибут: за ним нет def")

    nil
  end

  # ---

  defp misplaced(:def),
    do: "@opts_schema стоит над def, раскрытым мимо Core.Options (defdelegate, Kernel.def, тело не do:)"

  defp misplaced(kind), do: "@opts_schema стоит над #{kind}: схема опций — только у def"

  # ===== def =====

  @doc """
  Голова без тела — `Kernel.def/1`. В модуле с `use Core.Options` схема над головой объявляется на
  ней: `@doc` головы получает раздел «Опции».
  """
  # Credo читает `defmacro def(…)` как `def` без `@spec`, а `@spec def(…)` разобрать не может.
  # credo:disable-for-next-line Credo.Check.Readability.Specs
  defmacro def(call) do
    case options_module?(__CALLER__) and head_fun(call) do
      {_name, _arity} = fun ->
        quote do
          Core.Options.__head__(__MODULE__, unquote(fun), unquote(__CALLER__.line))
          Kernel.def(unquote(call))
        end

      _plain ->
        quote(do: Kernel.def(unquote(call)))
    end
  end

  @doc """
  `Kernel.def/2`, у которого тело раскрывается вместе с проверкой опций по `@opts_schema` над
  функцией (`@moduledoc`, «Подмена `def`»).

  В модуле без `use Core.Options` — `Kernel.def/2` как есть: так раскрывается `def` из `quote`
  модуля с `use Core.Options`, вставленный в чужой модуль.
  """
  # credo:disable-for-next-line Credo.Check.Readability.Specs
  defmacro def(call, expr) do
    if options_module?(__CALLER__) and Keyword.keyword?(expr) and Keyword.has_key?(expr, :do) do
      {var, problem} = opts_arg(call)

      quote do
        Kernel.def(unquote(call), do: Core.Options.__body__(unquote(var), unquote(problem), unquote(body(expr))))
      end
    else
      quote(do: Kernel.def(unquote(call), unquote(expr)))
    end
  end

  # ---

  defp options_module?(env), do: {:macro, __MODULE__} in Macro.Env.lookup_import(env, {:def, 2})

  defp head_fun({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp head_fun({name, _, context}) when is_atom(name) and is_atom(context), do: {name, 0}
  defp head_fun(_call), do: nil

  defp body(do: body), do: body
  defp body(expr), do: {:try, [], [expr]}

  defp opts_arg({:when, _, [head | guards]}), do: opts_arg(head, guards)
  defp opts_arg(head), do: opts_arg(head, [])

  defp opts_arg({_name, _, [_ | _] = args}, guards) do
    case List.last(args) do
      {:\\, _, [arg, _default]} -> opts_var(arg, guards)
      arg -> opts_var(arg, guards)
    end
  end

  defp opts_arg(_head, _guards), do: {nil, "у функции нет аргумента опций"}

  defp opts_var({name, _, context} = var, guards) when is_atom(name) and name != :_ and is_atom(context) do
    if guarded?(var, guards),
      do: {nil, "на опциях допустим только guard is_list/1"},
      else: {var, nil}
  end

  defp opts_var(arg, _guards), do: {nil, "опции — переменная, а не паттерн: #{Macro.to_string(arg)}"}

  defp guarded?(var, guards) do
    guards
    |> Enum.flat_map(&conjuncts/1)
    |> Enum.any?(&(not list_guard?(&1, var) and mentions?(&1, var)))
  end

  defp conjuncts({:and, _, [left, right]}), do: conjuncts(left) ++ conjuncts(right)
  defp conjuncts(guard), do: [guard]

  defp list_guard?({:is_list, _, [arg]}, var), do: same_var?(arg, var)
  defp list_guard?(_guard, _var), do: false

  defp mentions?(guard, var) do
    guard
    |> Macro.prewalk(false, fn node, found -> {node, found or same_var?(node, var)} end)
    |> elem(1)
  end

  defp same_var?({name, _, context}, {name, _, context}) when is_atom(name) and is_atom(context), do: true
  defp same_var?(_node, _var), do: false

  # ===== схема функции =====

  @doc false
  @spec __head__(module(), {atom(), arity()}, pos_integer()) :: :ok

  def __head__(module, {name, arity} = fun, line) when is_atom(module) and is_integer(line) do
    case Module.get_attribute(module, :opts_schema) do
      nil -> :ok
      raw -> declare!(module, fun, raw, line, "#{@label}: #{name}/#{arity}")
    end

    :ok
  end

  @doc false
  defmacro __body__(var, problem, body) do
    %Macro.Env{module: module, function: {name, arity} = fun, line: line} = __CALLER__
    where = "#{@label}: #{name}/#{arity}"

    case schema!(module, fun, line, where) do
      nil ->
        body

      %{} = entry ->
        if problem, do: Helper.Opts.reject!(where, problem)

        checked(generated(var), entry, "#{inspect(module)}.#{name}/#{arity}", body, where)
    end
  end

  # ---

  defp schema!(module, fun, line, where) do
    case Module.get_attribute(module, :opts_schema) do
      nil -> Map.get(schemas(module), fun)
      raw -> declare!(module, fun, raw, line, where)
    end
  end

  defp declare!(module, fun, raw, line, where) do
    case Module.get_definition(module, fun) do
      nil -> :ok
      {:v1, _kind, _meta, []} -> Helper.Opts.reject!(where, "@opts_schema ставится перед головой функции")
      {:v1, _kind, _meta, _clauses} -> Helper.Opts.reject!(where, "@opts_schema ставится перед первой клаузой функции")
    end

    Module.delete_attribute(module, :opts_schema)
    entry = compile!(raw, where)
    document(module, entry.schema, line)
    Module.put_attribute(module, :core_options_schemas, Map.put(schemas(module), fun, entry))
    entry
  end

  defp schemas(module), do: Module.get_attribute(module, :core_options_schemas) || %{}

  defp compile!(raw, where) do
    unless Keyword.keyword?(raw) and raw != [],
      do: Helper.Opts.reject!(where, "@opts_schema: ожидается непустая keyword-схема, получено #{inspect(raw)}")

    schema = new!(raw, where)

    case undocumented(schema.schema, []) do
      [] -> %{schema: schema, defaults: defaults!(schema, where)}
      keys -> Helper.Opts.reject!(where, "@opts_schema: ключи без doc: строкой: #{inspect(keys)}")
    end
  end

  defp new!(raw, where) do
    NimbleOptions.new!(raw)
  rescue
    error in ArgumentError -> Helper.Opts.reject!(where, "@opts_schema: #{Exception.message(error)}")
  end

  defp defaults!(%NimbleOptions{schema: schema} = compiled, where) do
    if Enum.any?(schema, fn {_key, spec} -> spec[:required] end) do
      :none
    else
      case NimbleOptions.validate([], compiled) do
        {:ok, defaults} -> {:ok, defaults}
        {:error, error} -> Helper.Opts.reject!(where, "@opts_schema: умолчание: #{Exception.message(error)}")
      end
    end
  end

  defp document(module, schema, line) do
    case Module.get_attribute(module, :doc) do
      {_line, false} ->
        :ok

      {doc_line, text} when is_binary(text) ->
        Module.put_attribute(module, :doc, {doc_line, String.trim_trailing(text) <> "\n\n" <> section(schema)})

      _none ->
        if Module.get_attribute(module, :impl) in [nil, false],
          do: Module.put_attribute(module, :doc, {line, section(schema)})
    end
  end

  defp section(schema), do: "## Опции\n\n" <> describe(schema)

  defp generated({name, meta, context}), do: {name, Keyword.put(meta, :generated, true), context}

  defp checked(var, %{schema: schema, defaults: :none}, label, body, where) do
    quote generated: true do
      unquote(var) = Core.Options.validate!(unquote(var), unquote(escape!(schema, where)), unquote(label))
      unquote(body)
    end
  end

  defp checked(var, %{schema: schema, defaults: {:ok, defaults}}, label, body, where) do
    quote generated: true do
      unquote(var) =
        case unquote(var) do
          [] -> unquote(escape!(defaults, where))
          given -> Core.Options.validate!(given, unquote(escape!(schema, where)), unquote(label))
        end

      unquote(body)
    end
  end

  defp escape!(value, where) do
    Macro.escape(value)
  rescue
    error in ArgumentError ->
      Helper.Opts.reject!(where, "@opts_schema: схема не сохраняется в коде: #{Exception.message(error)}")
  end

  # ===== описание =====

  @doc """
  Описание опций схемы `schema` (`NimbleOptions.docs/1`): ключ, тип, умолчание и `doc:` каждого.

  Тот же текст функция со схемой получает разделом «Опции» в `@doc`. Явный вызов нужен там, где
  `@doc` скрыт, — в `@moduledoc` OTP-процесса со схемой над `init/1`:

      @init_opts_schema [name: [type: :atom, required: true, doc: "Имя процесса."]]

      @moduledoc \"""
      ...

      ## Опции старта

      \#{Core.Options.docs(@init_opts_schema)}
      \"""

  Некорректная схема — `ArgumentError` NimbleOptions; ключ без `doc:` строкой — `ArgumentError`, как
  и у `@opts_schema`: неописанная опция не попадает в контракт.
  """
  @spec docs(keyword()) :: String.t()

  def docs(schema) when is_list(schema) do
    %NimbleOptions{schema: keys} = compiled = NimbleOptions.new!(schema)

    case undocumented(keys, []) do
      [] -> describe(compiled)
      missing -> raise ArgumentError, "Core.Options.docs/1: ключи без doc: строкой: #{inspect(missing)}"
    end
  end

  # ===== проверка =====

  @doc """
  Проверить `data` по схеме `schema` и вернуть их с умолчаниями; отказ — `ArgumentError`
  `"<label>: <сообщение NimbleOptions>"`.

  Тот же вызов функция со схемой делает над своими опциями. Явно он нужен для данных в форме опций,
  которые не последний аргумент функции, — элементов позиционного списка; опции самой функции так
  не проверяются: их проверяет `@opts_schema`. Схема собирается один раз — `NimbleOptions.new!/1` в
  атрибуте модуля; `label` называет функцию, отклонившую вызов (`"Mod.fun/2"`).

      @subscribers_schema NimbleOptions.new!(subscribers: [type: {:list, :keyword_list}, doc: "…"])

      Core.Options.validate!([subscribers: subscribers], @subscribers_schema, "MyApp.Notify.drain/2")
  """
  @spec validate!(term(), NimbleOptions.t(), String.t()) :: keyword()

  def validate!(data, %NimbleOptions{} = schema, label) when is_binary(label) do
    unless Keyword.keyword?(data),
      do: raise(ArgumentError, "#{label}: ожидается keyword-список опций, получено #{inspect(data)}")

    case NimbleOptions.validate(data, schema) do
      {:ok, validated} when is_list(validated) -> validated
      {:error, error} -> raise ArgumentError, "#{label}: #{Exception.message(error)}"
    end
  end

  # ===== общее =====

  defp describe(%NimbleOptions{} = schema), do: NimbleOptions.docs(schema)

  defp undocumented(schema, path) do
    Enum.flat_map(schema, fn {key, spec} ->
      own = if is_binary(spec[:doc]), do: [], else: [key_path(path, key)]
      nested = if is_list(spec[:keys]), do: undocumented(spec[:keys], path ++ [key]), else: []
      own ++ nested
    end)
  end

  defp key_path([], key), do: key
  defp key_path(path, key), do: path ++ [key]
end
