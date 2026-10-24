defmodule Core.Helper.Module do
  @moduledoc """
  Проверка экспорта модуля.

  `exports?/3` — замена `function_exported?/3`, который отвечает только про уже загруженный код:
  ещё не загруженный модуль (ленивая загрузка Mix в dev и test) он молча считает пустым
  (`docs/rules/20-agreements.md`, «Экспорт модуля»).
  """

  @doc """
  Модуль экспортирует `fun/arity`. Не загруженный модуль грузится, а при сборке — ждёт своей
  компиляции, поэтому ответ верен и при сборке, и в рантайме.
  """
  @spec exports?(module(), atom(), arity()) :: boolean()

  def exports?(mod, fun, arity) when is_atom(mod) and is_atom(fun) and is_integer(arity) do
    (:erlang.module_loaded(mod) or match?({:module, _}, Code.ensure_compiled(mod))) and
      function_exported?(mod, fun, arity)
  end
end
