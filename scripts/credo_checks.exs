# Проверки Credo проекта: подключаются через `requires:` в `.credo.exs` (цель `make credo`).
#
# `FunctionExported` — экспорт модуля только через `Core.Helper.Module.exports?/3`:
# `docs/rules/20-agreements.md`, «Экспорт модуля».
#
# `UseOpts` — разбор опций `use` при раскрытии: `docs/rules/20-agreements.md`, «Опции `use`».
#
# `OptsSchema` — опции функции читает схема: `docs/rules/20-agreements.md`, «Схема опций функции».

defmodule CredoChecks.FunctionExported do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      `function_exported?/3` и `:erlang.function_exported/3` отвечают только про уже загруженный код:
      ещё не загруженный модуль (ленивая загрузка Mix в dev и test) они молча считают пустым, и
      результат зависит от порядка тестов. Экспорт проверяется через `Core.Helper.Module.exports?/3`,
      который модуль грузит, а при сборке ждёт (`docs/rules/20-agreements.md`, «Экспорт модуля»).
      """
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    Credo.Code.prewalk(source_file, &walk/2, ctx).issues
  end

  defp walk({:function_exported?, meta, args} = ast, ctx) when is_nil(args) or length(args) == 3,
    do: {ast, put_issue(ctx, issue_for(ctx, meta, "function_exported?", "function_exported?"))}

  defp walk({{:., _, [{:__aliases__, _, [:Kernel]}, :function_exported?]}, meta, _args} = ast, ctx),
    do: {ast, put_issue(ctx, issue_for(ctx, meta, "Kernel.function_exported?", "function_exported?"))}

  defp walk({{:., _, [:erlang, :function_exported]}, meta, _args} = ast, ctx),
    do: {ast, put_issue(ctx, issue_for(ctx, meta, ":erlang.function_exported", "function_exported"))}

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta, call, trigger) do
    format_issue(ctx,
      message: "#{call} не грузит модуль — Core.Helper.Module.exports?/3",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end

defmodule CredoChecks.UseOpts do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Опции `use` разбираются при раскрытии: пролог `__using__` — `Core.Helper.Opts.expand!/3` →
      `validate!` → `literal!/3` (у обёрток Prim — `Core.Prim.Opts.prepare!`), опция-выражение
      уходит AST-ом в атрибут тела через `<key>!`. Поэтому в модуле с `__using__` нет
      `quote bind_quoted:`, первое употребление `opts` в `__using__` — аргумент пролога, а функций
      ключей (`required_keys/0`, `optional_keys/0`, `expression_keys/0`) нет вне протокола
      `Core.Prim.Wrapper` (`docs/rules/20-agreements.md`, «Опции `use`»; ADR-0085).
      """
    ]

  @key_funs ~w(required_keys optional_keys expression_keys)a
  @wrapper "lib/core/prim/wrapper.ex"
  @prologue [expand!: [:Core, :Helper, :Opts], prepare!: [:Core, :Prim, :Opts]]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    ast = SourceFile.ast(source_file)

    issues =
      Enum.flat_map(module_bodies(ast), &builder_issues(&1, ctx)) ++
        key_fun_issues(ast, source_file.filename, ctx)

    Enum.sort_by(issues, & &1.line_no)
  end

  defp module_bodies(ast) do
    {_ast, bodies} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [_name, [do: body]]} = node, acc -> {node, [own_body(body) | acc]}
        node, acc -> {node, acc}
      end)

    bodies
  end

  defp own_body(body) do
    Macro.prewalk(body, fn
      {:defmodule, _meta, _args} -> nil
      node -> node
    end)
  end

  defp builder_issues(body, ctx) do
    case using_clauses(body) do
      [] -> []
      clauses -> bind_quoted_issues(body, ctx) ++ Enum.flat_map(clauses, &prologue_issues(&1, ctx))
    end
  end

  defp using_clauses(body) do
    {_ast, clauses} =
      Macro.prewalk(body, [], fn
        {:defmacro, _meta, [head, block]} = node, acc ->
          case using_head(head) do
            :none -> {node, acc}
            {param, guards} -> {node, [{param, guards ++ [block]} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(clauses)
  end

  defp using_head({:when, _meta, [head, guard]}) do
    case using_head(head) do
      :none -> :none
      {param, guards} -> {param, [guard | guards]}
    end
  end

  defp using_head({:__using__, meta, [{:\\, _default_meta, [param, _default]}]}),
    do: using_head({:__using__, meta, [param]})

  defp using_head({:__using__, _meta, [param]}), do: {param, []}
  defp using_head(_head), do: :none

  defp bind_quoted_issues(body, ctx) do
    {_ast, issues} =
      Macro.prewalk(body, [], fn
        {:quote, meta, [opts | _rest]} = node, acc when is_list(opts) ->
          if Keyword.keyword?(opts) and Keyword.has_key?(opts, :bind_quoted),
            do: {node, [bind_quoted_issue(ctx, meta) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    issues
  end

  defp bind_quoted_issue(ctx, meta) do
    format_issue(ctx,
      message: "quote bind_quoted: в модуле с __using__ — опции разбираются при раскрытии (Core.Helper.Opts)",
      trigger: "quote",
      line_no: meta[:line],
      column: meta[:column]
    )
  end

  defp prologue_issues({{name, _meta, context}, guards_and_block}, ctx) when is_atom(name) and is_atom(context) do
    if String.starts_with?(Atom.to_string(name), "_") do
      []
    else
      case first_use_in(guards_and_block, name) do
        {:bypass, meta} -> [prologue_issue(ctx, meta, name)]
        _prologue_or_none -> []
      end
    end
  end

  defp prologue_issues(_pattern, _ctx), do: []

  defp prologue_issue(ctx, meta, name) do
    format_issue(ctx,
      message:
        "#{name} в __using__ употреблён мимо пролога — Core.Helper.Opts.expand!/3 " <>
          "(у обёрток Prim — Core.Prim.Opts.prepare!)",
      trigger: Atom.to_string(name),
      line_no: meta[:line],
      column: meta[:column]
    )
  end

  defp first_use({name, meta, context}, name) when is_atom(context), do: {:bypass, meta}

  defp first_use({:|>, _meta, [{name, _var_meta, context}, call]} = node, name) when is_atom(context),
    do: prologue_or_walk(call, node, name)

  defp first_use({{:., _dot, _target}, _meta, [{name, _var_meta, context} | _rest]} = node, name)
       when is_atom(context),
       do: prologue_or_walk(node, node, name)

  defp first_use({:=, _meta, [_pattern, value]}, name), do: first_use(value, name)
  defp first_use({form, _meta, args}, name) when is_list(args), do: first_use_in([form | args], name)
  defp first_use({left, right}, name), do: first_use_in([left, right], name)
  defp first_use(list, name) when is_list(list), do: first_use_in(list, name)
  defp first_use(_ast, _name), do: :none

  defp prologue_or_walk(call, {form, _meta, args}, name) do
    if prologue_call?(call), do: :prologue, else: first_use_in([form | args], name)
  end

  defp first_use_in(nodes, name) do
    Enum.reduce_while(nodes, :none, fn node, :none ->
      case first_use(node, name) do
        :none -> {:cont, :none}
        found -> {:halt, found}
      end
    end)
  end

  defp prologue_call?({{:., _dot, [{:__aliases__, _meta, segments}, fun]}, _call_meta, _args}) do
    case Keyword.fetch(@prologue, fun) do
      {:ok, full} -> Enum.take(full, -length(segments)) == segments
      :error -> false
    end
  end

  defp prologue_call?(_call), do: false

  defp key_fun_issues(ast, filename, ctx) do
    if String.ends_with?(filename, @wrapper) do
      []
    else
      {_ast, issues} = Macro.prewalk(ast, [], &key_fun(&1, &2, ctx))
      issues
    end
  end

  defp key_fun({:def, _meta, [head | _body]} = node, acc, ctx) do
    case key_fun_head(head) do
      {name, meta} -> {node, [key_fun_issue(ctx, meta, name) | acc]}
      :none -> {node, acc}
    end
  end

  defp key_fun(node, acc, _ctx), do: {node, acc}

  defp key_fun_head({:when, _meta, [head, _guard]}), do: key_fun_head(head)
  defp key_fun_head({name, meta, args}) when name in @key_funs and args in [nil, []], do: {name, meta}
  defp key_fun_head(_head), do: :none

  defp key_fun_issue(ctx, meta, name) do
    format_issue(ctx,
      message: "#{name}/0 — функция ключей builder'а: ключи — атрибуты модуля (кроме Core.Prim.Wrapper)",
      trigger: Atom.to_string(name),
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end

defmodule CredoChecks.OptsSchema do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Функция, которая сама читает свои опции, объявляет схему `@opts_schema` над `def` в модуле с
      `use Core.Options`: тогда опечатка в ключе — `ArgumentError`, а не молчаливое умолчание
      (`docs/rules/20-agreements.md`, «Схема опций функции»). Проверка срабатывает на
      `Keyword.validate!(opts, …)` и на чтение `Keyword.get/fetch/fetch!(opts, …)` / `opts[:…]` в
      теле публичной функции без схемы.

      Не срабатывает на обратных вызовах с `@impl`, на функциях, отдающих `opts` целиком дальше, и в
      модулях, которые разбирают опции как данные (`parsers:`).
      """,
      params: [parsers: "Модули разбора опций как данных: опции `use` и объявления, не опции вызова."]
    ],
    param_defaults: [
      parsers: ~w(Core.Helper.Opts Core.Prim.Opts Core.Prim.Wrapper Core.Codec.Plugin.Opts Core.Es.Store.Opts
           Core.Es.Aggregate.Repo.Pg.Snapshot)
    ]

  @reads ~w(get get_lazy fetch fetch! validate validate! has_key?)a
  @transparent ~w(__block__ case cond if unless with fn try receive when and or not ! && || == != === !== ++ -- in)a
  @blocks ~w(do else after rescue catch)a

  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    parsers = Params.get(params, :parsers, __MODULE__)

    source_file
    |> SourceFile.ast()
    |> modules([])
    |> Enum.reject(fn {name, _body} -> name in parsers end)
    |> Enum.flat_map(fn {_name, body} -> module_issues(body, ctx) end)
    |> Enum.sort_by(& &1.line_no)
  end

  # ---

  defp modules(ast, parent) do
    {_ast, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [{:__aliases__, _alias, segments}, [do: body]]}, acc ->
          name = parent ++ Enum.map(segments, &segment/1)
          {nil, acc ++ [{Enum.join(name, "."), own_body(body)} | modules(body, name)]}

        node, acc ->
          {node, acc}
      end)

    modules
  end

  defp segment(segment) when is_atom(segment), do: Atom.to_string(segment)
  defp segment(segment), do: Macro.to_string(segment)

  defp own_body(body) do
    Macro.prewalk(body, fn
      {:defmodule, _meta, _args} -> nil
      node -> node
    end)
  end

  defp module_issues(body, ctx) do
    state = %{exempt?: false, exempt: MapSet.new(), helpers: helpers(body), issues: []}
    {_ast, state} = Macro.prewalk(body, state, &form(&1, &2, ctx))
    state.issues
  end

  # Приватные функции модуля: опции, отданные им, остаются в модуле, и их чтение — чтение
  # вызывающего.
  defp helpers(body) do
    {_ast, helpers} =
      Macro.prewalk(body, %{}, fn
        {:quote, _meta, _args}, helpers ->
          {nil, helpers}

        {:defp, _meta, [head, blocks]}, helpers when is_list(blocks) ->
          {nil, Map.update(helpers, fun(head), [{args(head), blocks}], &(&1 ++ [{args(head), blocks}]))}

        node, helpers ->
          {node, helpers}
      end)

    helpers
  end

  # Схема и `@impl` относятся к функции (имя и арность), а не к клаузе: стоят над первой. `def` внутри
  # `quote` — генерируемый код, схема в нём MUST NOT.
  defp form({:quote, _meta, _args}, state, _ctx), do: {nil, state}
  defp form({:@, _meta, [{:opts_schema, _attr, _value}]}, state, _ctx), do: {nil, %{state | exempt?: true}}
  defp form({:@, _meta, [{:impl, _attr, [false]}]} = node, state, _ctx), do: {node, state}
  defp form({:@, _meta, [{:impl, _attr, [_value]}]}, state, _ctx), do: {nil, %{state | exempt?: true}}

  defp form({kind, _meta, [head | blocks]}, state, ctx) when kind in ~w(def defp defmacro defmacrop)a do
    fun = fun(head)
    exempt = if state.exempt?, do: MapSet.put(state.exempt, fun), else: state.exempt
    state = %{state | exempt?: false, exempt: exempt}

    case blocks do
      [blocks] when kind == :def and is_list(blocks) ->
        if MapSet.member?(exempt, fun),
          do: {nil, state},
          else: {nil, %{state | issues: clause_issues(head, blocks, state.helpers, ctx) ++ state.issues}}

      _private_or_head ->
        {nil, state}
    end
  end

  defp form(node, state, _ctx), do: {node, state}

  defp fun({:when, _meta, [head, _guards]}), do: fun(head)
  defp fun({name, _meta, args}) when is_list(args), do: {name, length(args)}
  defp fun({name, _meta, _context}), do: {name, 0}

  defp args({:when, _meta, [head, _guards]}), do: args(head)
  defp args({_name, _meta, args}) when is_list(args), do: Enum.map(args, &param/1)
  defp args(_head), do: []

  defp param({:\\, _meta, [param, _default]}), do: param(param)
  defp param({name, _meta, context}) when is_atom(name) and is_atom(context), do: name
  defp param(_pattern), do: nil

  # Функция, отдающая `opts` целиком дальше (аргументом вызова, в данных результата), опции не
  # читает: ключи проверяет получатель. `Keyword.validate!` — проверка своих ключей и при передаче.
  defp clause_issues(head, blocks, helpers, ctx) do
    if :opts in args(head) do
      env = %{var: :opts, consumer?: false, helpers: helpers, seen: MapSet.new(), site: nil}
      uses = walk_each(Keyword.values(blocks), env, %{reads: [], passed?: false})

      uses.reads
      |> Enum.reverse()
      |> Enum.filter(fn {_meta, fun} -> not uses.passed? or fun in ~w(validate validate!)a end)
      |> Enum.take(1)
      |> Enum.map(fn {meta, _fun} -> issue(ctx, meta) end)
    else
      []
    end
  end

  # `consumer?` — узел стоит внутри аргументов вызова или литерала данных: голая переменная опций
  # здесь уходит дальше целиком. Управляющие формы и правка через `Keyword.*` её не отдают. `site` —
  # место передачи опций в приватную функцию: чтение внутри неё отмечается там.
  defp walk({:|>, _meta, [left, {call, meta, args}]}, env, acc) when is_list(args),
    do: walk({call, meta, [left | args]}, env, acc)

  defp walk({{:., _dot, [{:__aliases__, _alias, [:Keyword]}, fun]}, _call, [{var, meta, context} | rest]}, env, acc)
       when var == env.var and fun in @reads and is_atom(context),
       do: walk_each(rest, env, read(acc, env, meta, fun))

  defp walk({{:., _dot, [Access, :get]}, _call, [{var, meta, context} | rest]}, env, acc)
       when var == env.var and is_atom(context),
       do: walk_each(rest, env, read(acc, env, meta, :get))

  defp walk({{:., _dot, [{:__aliases__, _alias, [:Keyword]}, _fun]}, _call, args}, env, acc),
    do: walk_each(args, env, acc)

  defp walk({var, _meta, context}, env, acc) when var == env.var and is_atom(context),
    do: %{acc | passed?: acc.passed? or env.consumer?}

  defp walk({:quote, _meta, args}, env, acc) do
    {_ast, unquoted} =
      Macro.prewalk(args, [], fn
        {:unquote, _meta, [value]}, unquoted -> {nil, [value | unquoted]}
        node, unquoted -> {node, unquoted}
      end)

    walk_each(unquoted, %{env | consumer?: true}, acc)
  end

  defp walk({form, _meta, [_pattern, value]}, env, acc) when form in ~w(= <- ->)a, do: walk(value, env, acc)

  defp walk({form, _meta, args}, env, acc) when form in @transparent and is_list(args),
    do: Enum.reduce(args, acc, &walk_control(&1, env, &2))

  defp walk({name, _meta, args} = call, env, acc) when is_atom(name) and is_list(args) do
    case Map.fetch(env.helpers, {name, length(args)}) do
      {:ok, clauses} -> walk_helper(call, clauses, env, acc)
      :error -> walk_each(args, %{env | consumer?: true}, acc)
    end
  end

  defp walk({_form, _meta, args}, env, acc) when is_list(args), do: walk_each(args, %{env | consumer?: true}, acc)
  defp walk({left, right}, env, acc), do: walk_each([left, right], %{env | consumer?: true}, acc)
  defp walk(list, env, acc) when is_list(list), do: walk_each(list, %{env | consumer?: true}, acc)
  defp walk(_ast, _env, acc), do: acc

  defp walk_control(list, env, acc) when is_list(list), do: Enum.reduce(list, acc, &walk_control(&1, env, &2))
  defp walk_control({key, value}, env, acc) when key in @blocks, do: walk_control(value, env, acc)
  defp walk_control(ast, env, acc), do: walk(ast, env, acc)

  defp walk_each(nodes, env, acc), do: Enum.reduce(nodes, acc, &walk(&1, env, &2))

  # Опции, отданные приватной функции голой переменной, читаются её телом: оно разбирается с
  # переменной её параметра, а результат вызова уходит туда же, куда уходил бы сам вызов.
  defp walk_helper({name, _meta, args}, clauses, env, acc) do
    fun = {name, length(args)}
    {given, rest} = Enum.split_with(Enum.with_index(args), fn {arg, _index} -> var?(arg, env.var) end)
    acc = walk_each(Enum.map(rest, &elem(&1, 0)), %{env | consumer?: true}, acc)

    if MapSet.member?(env.seen, fun) do
      acc
    else
      env = %{env | seen: MapSet.put(env.seen, fun)}

      for {{_var, meta, _context}, index} <- given,
          {params, blocks} <- clauses,
          param = Enum.at(params, index),
          param != nil,
          reduce: acc,
          do: (acc -> walk_each(Keyword.values(blocks), %{env | var: param, site: env.site || meta}, acc))
    end
  end

  defp var?({var, _meta, context}, var) when is_atom(context), do: true
  defp var?(_ast, _var), do: false

  defp read(acc, env, meta, fun), do: %{acc | reads: [{env.site || meta, fun} | acc.reads]}

  defp issue(ctx, meta) do
    format_issue(ctx,
      message: "opts читается мимо схемы — @opts_schema над def (use Core.Options) либо опции насквозь",
      trigger: "opts",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end

defmodule CredoChecks.UseOptsPerLine do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: """
      В `use` каждая опция стоит на отдельной строке (`docs/rules/20-agreements.md`, «Стиль
      кодирования»): опции `use` — объявление модуля, и построчно они читаются как таблица.
      Единственная опция MAY стоять в строке `use` (`use ExUnit.Case, async: true`); от двух и
      больше — каждая на своей строке, и ни одна не в строке `use`.
      """
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)

    {:ok, ast} =
      source_file
      |> SourceFile.source()
      |> Code.string_to_quoted(columns: true, literal_encoder: &{:ok, {:__block__, &2, [&1]}})

    {_ast, issues} = Macro.prewalk(ast, [], &walk(&1, &2, ctx))
    Enum.reverse(issues)
  end

  # ---

  defp walk({:use, meta, [_module, opts]} = node, issues, ctx) do
    lines = Enum.map(keyword(opts), &key_line/1)

    if one_per_line?(lines, meta[:line]),
      do: {node, issues},
      else: {node, [issue(ctx, meta) | issues]}
  end

  defp walk(node, issues, _ctx), do: {node, issues}

  defp one_per_line?([_one], _use_line), do: true
  defp one_per_line?([], _use_line), do: true
  defp one_per_line?(lines, use_line), do: use_line not in lines and length(Enum.uniq(lines)) == length(lines)

  defp keyword({:__block__, _meta, [list]}) when is_list(list), do: keyword(list)
  defp keyword(list) when is_list(list), do: Enum.filter(list, &match?({{:__block__, _meta, [_key]}, _value}, &1))
  defp keyword(_opts), do: []

  defp key_line({{:__block__, meta, [_key]}, _value}), do: meta[:line]

  defp issue(ctx, meta) do
    format_issue(ctx,
      message: "опции use — каждая на отдельной строке, не в строке use",
      trigger: "use",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end

defmodule CredoChecks.EnumValuesTable do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: """
      Каждое значение `Core.Enum` описано строкой таблицы `| Значение | … |` в `@moduledoc` своего
      модуля, первая ячейка — значение в форме `inspect/1` в обратных кавычках (`` `:in_work` ``):
      `docs/rules/11-domain.md`, «Описание значений в `@moduledoc`». Значения берутся из литерала
      `values:` / ключей `codes:`; `values:` или `@moduledoc` не литералом — модуль пропускается.
      """
    ]

  @values_header "Значение"

  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)

    {_ast, issues} =
      Macro.prewalk(SourceFile.ast(source_file), [], fn
        {:defmodule, _meta, [_name, [do: body]]} = node, acc -> {node, module_issues(own_body(body), ctx) ++ acc}
        node, acc -> {node, acc}
      end)

    Enum.sort_by(issues, & &1.line_no)
  end

  # ---

  defp own_body(body) do
    Macro.prewalk(body, fn
      {:defmodule, _meta, _args} -> nil
      node -> node
    end)
  end

  defp module_issues(body, ctx) do
    with {meta, opts} <- enum_use(body),
         {:ok, values} <- values(opts),
         {:ok, doc} <- moduledoc(body) do
      cells = table_cells(doc)

      case Enum.reject(values, &(cell(&1) in cells)) do
        [] -> []
        missing -> [issue(ctx, meta, missing)]
      end
    else
      _skip -> []
    end
  end

  defp enum_use(body) do
    {_ast, found} =
      Macro.prewalk(body, nil, fn
        {:use, meta, [{:__aliases__, _alias, [:Core, :Enum]}, opts]} = node, nil when is_list(opts) ->
          {node, {meta, opts}}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp values(opts) do
    case {Keyword.get(opts, :values), Keyword.get(opts, :codes)} do
      {values, nil} -> atoms(values)
      {nil, {:%{}, _meta, pairs}} -> atoms(Enum.map(pairs, &elem(&1, 0)))
      _other -> :skip
    end
  end

  defp atoms({:sigil_w, _meta, [{:<<>>, _bin, [words]}, ~c"a"]}) when is_binary(words),
    do: {:ok, Enum.map(String.split(words), &String.to_atom/1)}

  defp atoms(list) when is_list(list) do
    if Enum.all?(list, &is_atom/1), do: {:ok, list}, else: :skip
  end

  defp atoms(_values), do: :skip

  defp moduledoc(body) do
    {_ast, doc} =
      Macro.prewalk(body, {:ok, ""}, fn
        {:@, _meta, [{:moduledoc, _attr, [doc]}]} = node, _acc -> {node, doc_text(doc)}
        node, acc -> {node, acc}
      end)

    doc
  end

  defp doc_text(doc) when is_binary(doc), do: {:ok, doc}
  defp doc_text({:sigil_S, _meta, [{:<<>>, _bin, [doc]}, _mods]}) when is_binary(doc), do: {:ok, doc}
  defp doc_text(false), do: {:ok, ""}
  defp doc_text(_doc), do: :skip

  defp table_cells(doc) do
    doc
    |> String.split("\n")
    |> Enum.chunk_by(&table_line?/1)
    |> Enum.filter(&values_table?/1)
    |> Enum.flat_map(fn [_header, _separator | rows] -> Enum.map(rows, &first_cell/1) end)
  end

  defp values_table?([header, _separator | _rows]), do: table_line?(header) and first_cell(header) == @values_header
  defp values_table?(_lines), do: false

  defp table_line?(line), do: String.starts_with?(String.trim_leading(line), "|")

  defp first_cell(line), do: String.trim(Enum.at(String.split(line, "|", parts: 3), 1, ""))

  defp cell(value), do: "`#{inspect(value)}`"

  defp issue(ctx, meta, missing) do
    format_issue(ctx,
      message:
        "значения Core.Enum без строки таблицы | Значение | в @moduledoc: " <>
          Enum.map_join(missing, ", ", &cell/1),
      trigger: "use",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
