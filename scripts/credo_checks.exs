# Проверки Credo проекта: подключаются через `requires:` в `.credo.exs` (цель `make credo`).
#
# `FunctionExported` — экспорт модуля только через `Core.Helper.Module.exports?/3`:
# `docs/rules/20-agreements.md`, «Экспорт модуля».

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
