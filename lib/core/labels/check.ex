defmodule Core.Labels.Check do
  @moduledoc """
  Compile-time проверки объявлений подписей (`Core.Labels.*`): текст подписи и keyword-список
  решений без повторов.

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
