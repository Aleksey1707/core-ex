# Проверки Credo проекта: подключаются через `requires:` в `.credo.exs` (цель `make credo`).
#
# `FunctionExported` — экспорт модуля только через `Core.Helper.Module.exports?/3`:
# `docs/rules/20-agreements.md`, «Экспорт модуля».
#
# `UseOpts` — разбор опций `use` при раскрытии: `docs/rules/20-agreements.md`, «Опции `use`».

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
