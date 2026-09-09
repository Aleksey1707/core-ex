defmodule Core.Helper.StartOpts do
  @moduledoc """
  Проверка опций OTP-процесса в `init/1`.

  Опции приходят из дерева супервизии потребителя и разбираются один раз: ошибка в них —
  ошибка конфигурации. `ArgumentError` в `init/1` называет опцию и ожидаемое значение,
  тогда как непроверенное значение всплывает позже и хуже: `FunctionClauseError` в
  `handle_continue/2` (супервизор уходит в цикл рестартов) или молчаливый backoff, в
  котором опечатка неотличима от недоступного брокера (`17-otp-concurrency.md`).

  `Core.Helper.Opts` — про опции `use`-макросов и compile-time; здесь — рантайм.
  `label` у всех функций — имя процесса для текста ошибки (`"Mq.Stream.Reader"`).
  """

  @doc "Обязательная опция-модуль."
  @spec module!(String.t(), keyword(), atom()) :: module()

  def module!(label, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_atom(value) and not is_nil(value) -> value
      {:ok, other} -> raise_invalid!(label, key, "модуль", other)
      :error -> raise_missing!(label, key)
    end
  end

  @doc "Обязательная опция — структура `mod`."
  @spec prim!(String.t(), keyword(), atom(), module()) :: struct()

  def prim!(label, opts, key, mod) do
    case Keyword.fetch(opts, key) do
      {:ok, %{__struct__: ^mod} = value} -> value
      {:ok, other} -> raise_invalid!(label, key, "%#{inspect(mod)}{}", other)
      :error -> raise_missing!(label, key)
    end
  end

  @doc "Обязательная опция-атом (имя, ключ, тег)."
  @spec atom!(String.t(), keyword(), atom()) :: atom()

  def atom!(label, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_atom(value) and not is_nil(value) -> value
      {:ok, other} -> raise_invalid!(label, key, "атом", other)
      :error -> raise_missing!(label, key)
    end
  end

  @doc "Обязательная опция — непустая строка."
  @spec binary!(String.t(), keyword(), atom()) :: String.t()

  def binary!(label, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> value
      {:ok, other} -> raise_invalid!(label, key, "непустую строку", other)
      :error -> raise_missing!(label, key)
    end
  end

  @doc "Опция — положительное целое; `default` при отсутствии."
  @spec pos_integer!(String.t(), keyword(), atom(), pos_integer()) :: pos_integer()

  def pos_integer!(label, opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      other -> raise_invalid!(label, key, "положительное целое", other)
    end
  end

  @doc "Опция — булево; `default` при отсутствии."
  @spec boolean!(String.t(), keyword(), atom(), boolean()) :: boolean()

  def boolean!(label, opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> value
      other -> raise_invalid!(label, key, "true или false", other)
    end
  end

  @doc "Опция — значение из `allowed`; `default` при отсутствии."
  @spec one_of!(String.t(), keyword(), atom(), [term()], term()) :: term()

  def one_of!(label, opts, key, allowed, default) do
    value = Keyword.get(opts, key, default)

    if value in allowed,
      do: value,
      else: raise_invalid!(label, key, "одно из #{inspect(allowed)}", value)
  end

  @doc "Поднять ошибку о недопустимом значении опции: для проверок сложнее перечисления."
  @spec raise_invalid!(String.t(), atom(), String.t(), term()) :: no_return()

  def raise_invalid!(label, key, expected, value) do
    raise ArgumentError,
          "#{label}: опция #{inspect(key)} — ожидается #{expected}, получено #{inspect(value)}"
  end

  # ---

  defp raise_missing!(label, key) do
    raise ArgumentError, "#{label}: нет обязательной опции #{inspect(key)}"
  end
end
