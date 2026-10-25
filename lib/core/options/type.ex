defmodule Core.Options.Type do
  @moduledoc """
  Custom-типы схемы опций: `{:custom, Core.Options.Type, fun, args}` в `@opts_schema`
  (`Core.Options`) и в схеме `Core.Options.validate!/3`.

  Типы — `prim/2`, `module/1`, `atom/1`, `binary/1`, `term/1`. Они возвращают `{:ok, value}` или
  `{:error, "ожидается …, получено …"}`; ключ в текст отказа добавляет NimbleOptions. Простые
  значения (целое, булево, функция, атом, где допустим `nil`) — встроенные типы NimbleOptions.

  `prim_option/2` — описание обязательного Prim-ключа целиком (тип, `type_doc:`, `doc:`), его
  ставят в схему: `topic: Core.Options.Type.prim_option(Core.Mq.Topic, "Топик.")`.

  Типы опций OTP-процесса (имя, `shutdown`) — `Core.Helper.StartOpts`.
  """

  alias Core.Result

  @doc "Значение — структура `mod` (Prim): `{:custom, Core.Options.Type, :prim, [mod]}`."
  @spec prim(term(), module()) :: Result.t(struct(), String.t())

  def prim(%{__struct__: mod} = value, mod) when is_atom(mod), do: {:ok, value}
  def prim(value, mod) when is_atom(mod), do: invalid("%#{inspect(mod)}{}", value)

  @doc "Значение — модуль: атом, кроме `nil`; `{:custom, Core.Options.Type, :module, []}`."
  @spec module(term()) :: Result.t(module(), String.t())

  def module(value) when is_atom(value) and not is_nil(value), do: {:ok, value}
  def module(value), do: invalid("модуль", value)

  @doc "Значение — атом, кроме `nil` (имя, ключ, тег): `{:custom, Core.Options.Type, :atom, []}`."
  @spec atom(term()) :: Result.t(atom(), String.t())

  def atom(value) when is_atom(value) and not is_nil(value), do: {:ok, value}
  def atom(value), do: invalid("атом", value)

  @doc "Значение — непустая строка: `{:custom, Core.Options.Type, :binary, []}`."
  @spec binary(term()) :: Result.t(String.t(), String.t())

  def binary(value) when is_binary(value) and value != "", do: {:ok, value}
  def binary(value), do: invalid("непустая строка", value)

  @doc "Значение — любое, кроме `nil` (например, handle процесса); `{:custom, Core.Options.Type, :term, []}`."
  @spec term(term()) :: Result.t(term(), String.t())

  def term(nil), do: invalid("значение", nil)
  def term(value), do: {:ok, value}

  @doc "Обязательный ключ схемы — структура `mod` (`prim/2`); `doc` — его описание."
  @spec prim_option(module(), String.t()) :: keyword()

  def prim_option(mod, doc) when is_atom(mod) and is_binary(doc),
    do: [type: {:custom, __MODULE__, :prim, [mod]}, type_doc: "`t:#{inspect(mod)}.t/0`", required: true, doc: doc]

  # ---

  defp invalid(expected, value), do: {:error, "ожидается #{expected}, получено #{inspect(value)}"}
end
