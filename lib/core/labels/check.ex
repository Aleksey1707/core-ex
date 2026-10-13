defmodule Core.Labels.Check do
  @moduledoc """
  Compile-time проверки объявлений подписей (`Core.Labels.*`): текст подписи, keyword-список
  решений без повторов, захват функции и Prim — хост объявления вида значения.

  Общие для всех `use Core.Labels.*`: опции `use` проверяет `Core.Helper.Opts.validate!/4`, а
  значения опций — эти функции. `where` — префикс текста ошибки, по которому видно объявление и
  опцию (`"Labels.Fields MyApp.Payload: labels:"`); текст после него начинается с ` — `.
  """

  @doc "Проверить текст подписи: непустая строка; строка из одних пробелов — пустая."
  @spec text!(term(), String.t()) :: String.t()

  def text!(text, where) when is_binary(where) do
    if is_binary(text) and String.trim(text) != "" do
      text
    else
      raise CompileError, description: "#{where} — непустая строка, задано #{inspect(text)}"
    end
  end

  @doc """
  Проверить захват функции заданной арности (`&Mod.fun/1`): анонимная функция модуля, который ещё
  собирается, в атрибут не сохраняется.
  """
  @spec capture!(term(), arity(), String.t()) :: function()

  def capture!(fun, arity, where) when is_integer(arity) and is_binary(where) do
    if is_function(fun, arity) and Function.info(fun, :type) == {:type, :external} do
      fun
    else
      raise CompileError,
        description: "#{where} — захват функции арности #{arity} (`&Mod.fun/#{arity}`), задано #{inspect(fun)}"
    end
  end

  @doc """
  Проверить хост объявления вида значения (`Core.Labels.ID`, `Core.Labels.Text`): Prim, объявленный
  выше, без второго такого объявления — значение выходит в сведения одним способом.
  """
  @spec prim!(module(), String.t(), String.t()) :: :ok

  def prim!(module, macro, where) when is_atom(module) and is_binary(macro) and is_binary(where) do
    cond do
      not Module.defines?(module, {:__domain_kind__, 0}) ->
        raise CompileError, description: "#{where}: не Prim: `use #{macro}` подключается после `use Core.Prim.*`"

      Module.defines?(module, {:__label_id__, 0}) or Module.defines?(module, {:__label_text__, 0}) ->
        raise CompileError,
          description:
            "#{where}: `use Core.Labels.ID` и `use Core.Labels.Text` вместе — " <>
              "значение выходит в сведения одним способом"

      true ->
        :ok
    end
  end

  @doc "Проверить keyword-список решений: непустой, без повторов ключа."
  @spec keyword!(term(), String.t()) :: keyword()

  def keyword!(list, where) when is_binary(where) do
    if not (is_list(list) and list != [] and Keyword.keyword?(list)) do
      raise CompileError, description: "#{where} — непустой keyword-список, задано #{inspect(list)}"
    end

    keys = Keyword.keys(list)

    case keys -- Enum.uniq(keys) do
      [] -> list
      repeated -> raise CompileError, description: "#{where} — ключи повторяются #{inspect(Enum.uniq(repeated))}"
    end
  end
end
