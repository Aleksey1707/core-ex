defmodule Core.Prim.Integer do
  @moduledoc """
  Билдер integer-Prim: `min:` / `max:` через `Validator.Integer`.

  Опции: `name:` (обязательна), `kind:`, `min:`, `max:`, `sec_max_len:`,
  `mutate:` / `validate:`, `sensitive:`, `personal:`.

  `sec_max_len` — граница **в байтах** для строкового ввода, отсекающая его до
  `Integer.parse/1`: разбор строит bignum по всей длине строки, а с ~2 млн цифр
  упирается в лимит BEAM и поднимает `SystemLimitError` мимо контракта `new/1`.
  Границы `min:` / `max:` от этого не защищают — они проверяются уже после разбора.
  Default выводится из `max:` (его десятичная запись + запас), а без `max:` — 40 байт.

  Опции-выражения (`docs/rules/20-agreements.md`, «Опции `use`»): `name:`, `mutate:`, `validate:` — проверяются в
  теле модуля; остальные опции — литералы.
  """

  alias Core.Helper
  alias Core.Prim
  alias Core.Result

  use Core.Prim.Wrapper,
    label: "Prim.Integer",
    native_kind: :integer,
    optional: ~w(min max sec_max_len)a

  @sec_max_len_slack 4
  @default_sec_max_len 40

  @doc "Объявить integer-Prim (`name:` + опции min/max)."
  defmacro __using__(opts) do
    opts = Prim.Opts.prepare!(opts, __CALLER__, __MODULE__)
    type_opts = Macro.escape(Keyword.take(opts, ~w(min max)a))

    base_opts =
      Prim.Wrapper.base_opts(opts, label()) ++
        [
          cast: quote(do: &Core.Prim.Integer.cast/2),
          validate: quote(do: {Core.Validator.Integer, unquote(type_opts)}),
          type_opts: type_opts,
          pipeline_opts: [sec_max_len: sec_max_len(opts)],
          value_type: quote(do: integer())
        ]

    quote do
      use Core.Prim, unquote(base_opts)
    end
  end

  @doc "Проверить значения опций-литералов билдера при раскрытии `use`."
  @spec validate_opts!(keyword()) :: :ok

  def validate_opts!(opts) do
    Prim.Opts.int_bounds!(opts, :min, :max, label())
    Prim.Opts.non_neg_integer!(opts, ~w(sec_max_len)a, label())
    fits_bounds!(opts)
  end

  @doc "Байтовая граница строкового ввода: явная `sec_max_len:` либо выведенная из границ."
  @spec sec_max_len(keyword()) :: pos_integer()

  def sec_max_len(type_opts) do
    Keyword.get(type_opts, :sec_max_len) || derived_sec_max_len(type_opts)
  end

  @doc false
  @spec cast(term()) :: Result.t(integer(), {:invalid_integer, String.t()})

  # Арность 1 — для вызова без опций (read-путь кодека): значение оттуда уже разобрано.
  def cast(value), do: cast(value, [])

  @doc false
  @spec cast(term(), keyword()) :: Result.t(integer(), {:invalid_integer, String.t()})

  def cast(value, _pipeline_opts) when is_integer(value), do: {:ok, value}

  def cast(value, pipeline_opts) when is_binary(value) do
    with :ok <-
           Prim.check_byte_limit(value, Keyword.get(pipeline_opts, :sec_max_len), :invalid_integer) do
      parse(value)
    end
  end

  def cast(_value, _pipeline_opts), do: invalid()

  # ---

  defp parse(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> invalid()
    end
  end

  defp invalid, do: {:error, {:invalid_integer, "невалидное значение"}}

  # Явная граница, в которую не влезает собственный `max:`, отвергает валидные значения.
  defp fits_bounds!(opts) do
    limit = sec_max_len(opts)

    case bound_bytes(opts) do
      nil ->
        :ok

      bytes when bytes <= limit ->
        :ok

      bytes ->
        Helper.Opts.reject!(
          label(),
          "sec_max_len (#{limit}) меньше десятичной записи границ (#{bytes} байт) — Prim не примет собственный max"
        )
    end
  end

  defp derived_sec_max_len(opts) do
    case bound_bytes(opts) do
      nil -> @default_sec_max_len
      bytes -> bytes + @sec_max_len_slack
    end
  end

  # Длину ввода ограничивает только верхняя граница: без `max:` любое число допустимо,
  # и вывести предел не из чего.
  defp bound_bytes(opts) do
    case Keyword.get(opts, :max) do
      nil -> nil
      max -> Enum.max(Enum.map(bounds(opts, max), &byte_size(Integer.to_string(&1))))
    end
  end

  defp bounds(opts, max) do
    case Keyword.get(opts, :min) do
      nil -> [max]
      min -> [min, max]
    end
  end
end
