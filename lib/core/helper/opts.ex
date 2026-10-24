defmodule Core.Helper.Opts do
  @moduledoc """
  Разбор опций `__using__`-макросов на этапе компиляции (ADR-0085, `docs/rules/20-agreements.md`,
  «Опции `use`»).

  ## Пролог

  Builder объявляет опции атрибутами `@required_keys`, `@optional_keys`, `@expression_keys` и
  разбирает их при раскрытии:

      defmacro __using__(opts) do
        opts = Helper.Opts.expand!(opts, __CALLER__, "Enum")
        Helper.Opts.validate!(opts, @required_keys, @optional_keys, "Enum")
        opts = Helper.Opts.literal!(opts, @expression_keys, "Enum")
        ...
      end

  `expand!/3` требует литеральный keyword-AST и раскрывает алиасы, `__MODULE__`, сигилы
  `~w()a` / `~D[]` / `~U[]` и унарный минус над числом. `validate!/4` проверяет обязательные и
  неизвестные ключи. `literal!/3` вычисляет опции-литералы и отдаёт опции-выражения AST-ом.
  Опция-ссылка на модуль без compile-ребра (атом без загрузки) раскрывается четвёртым аргументом
  `expand!/4` — `refs`.

  ## Опция-литерал и опция-выражение

  Опция-литерал — значение, для которого после `expand!/3` истинно `Macro.quoted_literal?/1`;
  иное значение такой опции — `CompileError` «ожидается литерал». Её проверяют при раскрытии:
  `module!/4`, `binary!/3`, `atom!/3`, `allowed!/4`; в `quote` значение уходит через
  `Macro.escape/1`.

  Опция-выражение (атрибут, вызов функции, захват) уходит AST-ом в атрибут тела через валидатор
  `<key>!`: `@doc false` функцию builder'а или value-вариант отсюда (`binary_value!/3`).

  `module_or_config!/4` — опция-модуль с дефолтом из `Core.Config`, резолвимым в рантайме.

  ## Тексты ошибок

  Все отказы — `CompileError` через `reject!/2` с префиксом `<метка>: <ключ>[: <элемент>…]: <текст>`:
  несовпадение формы или типа — «ожидается <что>, получено <значение>», смысловое нарушение —
  свободный текст. `file:` / `line:` не передаются: строку `use` даёт стек.
  """

  @doc """
  Раскрыть литералы опций `use`: алиасы, `__MODULE__`, сигилы `~w()a` / `~D[]` / `~U[]` и унарный
  минус над числом.

  Список опций MUST быть литеральным keyword-AST, иначе — `CompileError` «ожидается литеральный
  keyword». Обход значений идёт в списки и пары.

  `refs` — ключи опций-ссылок: модуль в них — атом без загрузки, и алиас раскрывается как в теле
  функции, с runtime-ребром xref вместо compile (`Core.Es.Event.Family`, `aggregate:` / `codec:`).
  """
  @spec expand!(Macro.t(), Macro.Env.t(), String.t(), [atom()]) :: keyword()

  def expand!(opts, %Macro.Env{} = caller, label, refs \\ []) when is_list(refs) do
    unless Keyword.keyword?(opts) do
      reject!(label, "ожидается литеральный keyword, получено #{Macro.to_string(opts)}")
    end

    # Контекст функции, а не тела модуля: ссылка на алиас даёт runtime-ребро xref.
    ref_env = %{caller | function: {:__ref__, 0}}

    Enum.map(opts, fn {key, value} ->
      env = if key in refs, do: ref_env, else: caller
      {key, expand_value(Macro.expand_literals(value, env), env)}
    end)
  end

  @doc """
  Проверить обязательные/опциональные ключи opts.

  `label` — имя билдера (`"Prim.String"`, `"Es.Outbox"`, ...): при вложенных `use`
  по тексту ошибки должно быть видно, какой из макросов её поднял.
  """
  @spec validate!(keyword(), [atom()], [atom()], String.t()) :: :ok

  def validate!(opts, required, optional, label) do
    keyword!(opts, label)

    allowed = required ++ optional

    unknown =
      opts
      |> Keyword.keys()
      |> Enum.uniq()
      |> Enum.reject(&(&1 in allowed))

    missing = Enum.reject(required, &Keyword.has_key?(opts, &1))

    case {missing, unknown} do
      {[], []} -> :ok
      {missing, unknown} -> reject!(label, options_error(missing, unknown))
    end
  end

  @doc """
  Потребовать литерал у всех опций, кроме `expression_keys`, и вычислить его.

  Литерал — значение, для которого после `expand!/3` истинно `Macro.quoted_literal?/1`; его AST
  вычисляется (кортеж или struct в AST значением не являются). Опции-выражения возвращаются AST
  как есть.
  """
  @spec literal!(keyword(), [atom()], String.t()) :: keyword()

  def literal!(opts, expression_keys, label) do
    Enum.map(opts, fn {key, value} -> {key, literal_value!(value, key in expression_keys, key, label)} end)
  end

  @doc """
  Проверить наличие обязательных ключей opts (без проверки неизвестных).

  Для билдеров с открытым списком опций.
  """
  @spec require!(keyword(), [atom()], String.t()) :: :ok

  def require!(opts, required, label) do
    keyword!(opts, label)

    missing = Enum.reject(required, &Keyword.has_key?(opts, &1))

    if missing != [], do: reject!(label, "нет обязательных опций: #{inspect(missing)}")

    :ok
  end

  @doc "Проверить, что `values` ⊆ `allowed`; `subject` — что именно перечисляется."
  @spec allowed!(term(), [term()], String.t(), String.t()) :: :ok

  def allowed!(values, allowed, subject, label) do
    unknown =
      values
      |> List.wrap()
      |> Enum.reject(&(&1 in allowed))

    if unknown != [], do: reject!(label, "неизвестные #{subject}: #{inspect(unknown)}")

    :ok
  end

  @doc """
  Прочитать опцию-модуль: скомпилирован и экспортирует всё требуемое.

  `checks` — `default:` (иначе опция обязательна) и `exports:` (список `{name, arity}`).
  """
  @spec module!(keyword(), atom(), String.t(), keyword()) :: module()

  def module!(opts, key, label, checks \\ []) do
    opts
    |> fetch!(key, label, checks)
    |> ensure_module!("#{label}: #{key}", Keyword.get(checks, :exports, []))
  end

  @doc """
  Опция-модуль либо AST рантайм-резолва значения из `Core.Config`.

  Результат подставляется в `quote` вызывающего макроса: без явной опции туда уходит
  **вызов** (`Core.Config.codec()`), а не запечённый модуль. Библиотека компилируется
  раньше конфигурации приложения-потребителя (и раньше `runtime.exs`), поэтому требовать
  значение `Core.Config` на этапе компиляции нельзя (`10-architecture.md`).

  `config_fun` — имя функции `Core.Config`: `:codec` или `:dao`.
  """
  @spec module_or_config!(keyword(), atom(), atom(), String.t()) :: module() | Macro.t()

  def module_or_config!(opts, key, config_fun, label) when config_fun in ~w(codec dao)a do
    case Keyword.get(opts, key) do
      nil -> quote(do: Core.Config.unquote(config_fun)())
      _module -> module!(opts, key, label)
    end
  end

  @doc "Прочитать опцию-строку."
  @spec binary!(keyword(), atom(), String.t()) :: String.t()

  def binary!(opts, key, label) do
    case fetch!(opts, key, label, []) do
      value when is_binary(value) ->
        value

      value ->
        reject!("#{label}: #{key}", "ожидается строка, получено #{inspect(value)}")
    end
  end

  @doc "Прочитать опцию-атом (не `nil`)."
  @spec atom!(keyword(), atom(), String.t()) :: atom()

  def atom!(opts, key, label) do
    case fetch!(opts, key, label, []) do
      value when is_atom(value) and not is_nil(value) ->
        value

      value ->
        reject!("#{label}: #{key}", "ожидается атом, получено #{inspect(value)}")
    end
  end

  @doc "Проверить значение опции-выражения в теле (`<key>!`): строка."
  @spec binary_value!(term(), atom(), String.t()) :: String.t()

  def binary_value!(value, _key, _label) when is_binary(value), do: value
  def binary_value!(value, key, label), do: reject!("#{label}: #{key}", "ожидается строка, получено #{inspect(value)}")

  @doc """
  Отказать в опции: `CompileError` «<where>: <message>».

  `where` — метка builder'а с путём до опции (`"Repo: only"`), `message` — что не так.
  """
  @spec reject!(String.t(), String.t()) :: no_return()

  def reject!(where, message) when is_binary(where) and is_binary(message),
    do: raise(CompileError, description: "#{where}: #{message}")

  # ---

  defp options_error(missing, unknown) do
    parts =
      for {keys, text} <- [{missing, "нет обязательных опций"}, {unknown, "неизвестные опции"}],
          keys != [],
          do: "#{text}: #{inspect(keys)}"

    Enum.join(parts, "; ")
  end

  defp expand_value({:sigil_w, _meta, _args} = sigil, caller), do: Macro.expand(sigil, caller)
  defp expand_value({:sigil_D, _meta, _args} = sigil, caller), do: Macro.expand(sigil, caller)
  defp expand_value({:sigil_U, _meta, _args} = sigil, caller), do: Macro.expand(sigil, caller)
  defp expand_value({:-, _meta, [number]}, _caller) when is_number(number), do: -number
  defp expand_value(list, caller) when is_list(list), do: Enum.map(list, &expand_value(&1, caller))
  defp expand_value({left, right}, caller), do: {expand_value(left, caller), expand_value(right, caller)}
  defp expand_value(value, _caller), do: value

  defp literal_value!(value, true = _expression?, _key, _label), do: value

  defp literal_value!(value, false = _expression?, key, label) do
    if Macro.quoted_literal?(value),
      do: elem(Code.eval_quoted(value), 0),
      else: reject!("#{label}: #{key}", "ожидается литерал, получено #{Macro.to_string(value)}")
  end

  defp fetch!(opts, key, label, checks) do
    keyword!(opts, label)

    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> default!(checks, key, label)
    end
  end

  defp default!(checks, key, label) do
    case Keyword.fetch(checks, :default) do
      {:ok, default} ->
        default

      :error ->
        reject!(label, "нет обязательных опций: #{inspect([key])}")
    end
  end

  defp ensure_module!(value, label, exports) when is_atom(value) and not is_nil(value) do
    Code.ensure_compiled!(value)
    Enum.each(exports, &ensure_exported!(value, &1, label))
    value
  end

  defp ensure_module!(value, label, _exports) do
    reject!(label, "ожидается модуль, получено #{inspect(value)}")
  end

  defp ensure_exported!(module, {name, arity}, label) do
    unless Core.Helper.Module.exports?(module, name, arity) do
      reject!(label, "модуль #{inspect(module)} должен экспортировать #{name}/#{arity}")
    end
  end

  defp keyword!(opts, label) do
    unless Keyword.keyword?(opts) do
      reject!(label, "ожидается keyword opts, получено #{inspect(opts)}")
    end
  end
end
