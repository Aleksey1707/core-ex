defmodule Core.Labels.Check do
  @moduledoc """
  Compile-time проверки объявлений подписей (`Core.Labels.*`): текст подписи, keyword-список
  решений без повторов, захват функции и Prim — хост объявления вида значения.

  Общие для всех `use Core.Labels.*`: опции `use` проверяет пролог `Core.Helper.Opts`, а значения
  опций — эти функции. Отказ — `Core.Helper.Opts.reject!/2`: `where` — метка builder'а и путь до
  опции через `: ` (`"Labels.Fields: labels: note"`), двоеточие после `where` ставит сама проверка.
  """

  alias Core.Helper
  alias Core.Helper.FieldCheck

  @doc "Проверить текст подписи: непустая строка; строка из одних пробелов — пустая."
  @spec text!(term(), String.t()) :: String.t()

  def text!(text, where) when is_binary(where) do
    if is_binary(text) and String.trim(text) != "",
      do: text,
      else: Helper.Opts.reject!(where, "ожидается непустая строка, получено #{inspect(text)}")
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
      Helper.Opts.reject!(
        where,
        "ожидается захват функции арности #{arity} (`&Mod.fun/#{arity}`), получено #{inspect(fun)}"
      )
    end
  end

  @doc """
  Проверить хост объявления вида значения (`Core.Labels.ID`, `Core.Labels.Text`): Prim, объявленный
  выше, без второго такого объявления — значение выходит в сведения одним способом.

  Признаки хоста читает `use` у владельцев: `prim?` — `Core.Prim.declared?/1`, `kinded?` —
  `Core.Labels.ID.declared?/1` или `Core.Labels.Text.declared?/1`.
  """
  @spec prim!(boolean(), boolean(), String.t(), String.t()) :: :ok

  def prim!(prim?, kinded?, macro, where)
      when is_boolean(prim?) and is_boolean(kinded?) and is_binary(macro) and is_binary(where) do
    cond do
      not prim? ->
        Helper.Opts.reject!(where, "не Prim: `use #{macro}` подключается после `use Core.Prim.*`")

      kinded? ->
        Helper.Opts.reject!(
          where,
          "`use Core.Labels.ID` и `use Core.Labels.Text` вместе — значение выходит в сведения одним способом"
        )

      true ->
        :ok
    end
  end

  @doc "Проверить keyword-список решений: непустой, без повторов ключа."
  @spec keyword!(term(), String.t()) :: keyword()

  def keyword!(list, where) when is_binary(where) do
    if not (is_list(list) and list != [] and Keyword.keyword?(list)) do
      Helper.Opts.reject!(where, "ожидается непустой keyword-список, получено #{inspect(list)}")
    end

    FieldCheck.unique!(Keyword.keys(list), where)

    list
  end
end
