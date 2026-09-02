defmodule Core.Helper.Opts do
  @moduledoc """
  Валидация опций `__using__`-макросов на этапе компиляции.

  `validate!/4` проверяет обязательные и неизвестные ключи, `module!/4` — что значение
  является модулем (и, при `exports:`, что он экспортирует нужные функции).
  Опечатка в опции даёт `CompileError`, а не сбой в рантайме.
  """

  @doc """
  Проверить обязательные/опциональные ключи opts.

  `label` — имя билдера (`"Prim.String"`, `"Es.Outbox"`, ...): при вложенных `use`
  по тексту ошибки должно быть видно, какой из макросов её поднял.
  """
  @spec validate!(keyword(), [atom()], [atom()], String.t()) :: :ok

  def validate!(opts, required, optional, label) do
    require!(opts, required, label)

    allowed = required ++ optional

    unknown =
      opts
      |> Keyword.keys()
      |> Enum.uniq()
      |> Enum.reject(&(&1 in allowed))

    if unknown != [] do
      raise CompileError, description: "#{label}: unknown option(s): #{inspect(unknown)}"
    end

    :ok
  end

  @doc """
  Проверить наличие обязательных ключей opts (без проверки неизвестных).

  Для билдеров с открытым списком опций — их сужают обёртки (`Core.Prim`).
  """
  @spec require!(keyword(), [atom()], String.t()) :: :ok

  def require!(opts, required, label) do
    keyword!(opts, label)

    missing = Enum.reject(required, &Keyword.has_key?(opts, &1))

    if missing != [] do
      raise CompileError, description: "#{label}: missing required option(s): #{inspect(missing)}"
    end

    :ok
  end

  @doc "Проверить, что `values` ⊆ `allowed`; `subject` — что именно перечисляется."
  @spec allowed!(term(), [term()], String.t(), String.t()) :: :ok

  def allowed!(values, allowed, subject, label) do
    unknown =
      values
      |> List.wrap()
      |> Enum.reject(&(&1 in allowed))

    if unknown != [] do
      raise CompileError, description: "#{label}: unknown #{subject}: #{inspect(unknown)}"
    end

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

  @doc "Прочитать опцию-строку."
  @spec binary!(keyword(), atom(), String.t()) :: String.t()

  def binary!(opts, key, label) do
    case fetch!(opts, key, label, []) do
      value when is_binary(value) ->
        value

      value ->
        raise CompileError,
          description: "#{label}: #{key}: ожидается строка, получено #{inspect(value)}"
    end
  end

  # ---

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
        raise CompileError, description: "#{label}: missing required option(s): #{inspect([key])}"
    end
  end

  defp ensure_module!(value, label, exports) when is_atom(value) and not is_nil(value) do
    Code.ensure_compiled!(value)
    Enum.each(exports, &ensure_exported!(value, &1, label))
    value
  end

  defp ensure_module!(value, label, _exports) do
    raise CompileError, description: "#{label}: ожидается модуль, получено #{inspect(value)}"
  end

  defp ensure_exported!(module, {name, arity}, label) do
    unless function_exported?(module, name, arity) do
      raise CompileError,
        description: "#{label}: модуль #{inspect(module)} должен экспортировать #{name}/#{arity}"
    end
  end

  defp keyword!(opts, label) do
    unless Keyword.keyword?(opts) do
      raise CompileError,
        description: "#{label}: ожидается keyword opts, получено #{inspect(opts)}"
    end
  end
end
