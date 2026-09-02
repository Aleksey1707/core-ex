defmodule Core.Prim.String do
  @moduledoc """
  Билдер string-Prim: `cast` → `mutate` (security-лимит + trim) → `Validator.String`.

  Опции: `name:` (обязательна), `kind:`, `min_len:`, `max_len:`, `sec_max_len:`, `re:`,
  `trim:` (default `true`), `mutate:` / `validate:` (кастомные шаги), `sensitive:`.

  `sec_max_len` — граница **в байтах**, отсекающая заведомо огромный ввод до посимвольных
  проверок; default — `max_len * 4 + 50` (4 байта на кодовую точку UTF-8 + запас).
  """

  alias Core.Helper
  alias Core.Prim
  alias Core.Validator

  @native_kind :string
  @required_keys ~w(name)a
  @optional_keys ~w(kind min_len max_len sec_max_len re trim mutate validate sensitive)a
  @sec_max_len_slack 50
  @max_utf8_bytes_per_char 4

  @doc "Объявить string-Prim (`name:` + опции длины/regex)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(
        opts,
        Core.Prim.String.required_keys(),
        Core.Prim.String.optional_keys(),
        "Prim.String"
      )

      native = Core.Prim.String.native_kind()
      kind = Keyword.get(opts, :kind, native)
      Prim.validate_kind!(native, kind)

      type_opts = Keyword.take(opts, ~w(min_len max_len sec_max_len re)a)

      mutate_opts = Keyword.put(type_opts, :trim, Keyword.get(opts, :trim, true))

      use Prim,
        cast: &Core.Prim.String.cast/1,
        mutate: &Core.Prim.String.mutate/2,
        validate: {Validator.String, type_opts},
        custom_mutate: Keyword.get(opts, :mutate),
        custom_validate: Keyword.get(opts, :validate),
        name: Keyword.fetch!(opts, :name),
        kind: kind,
        type_opts: mutate_opts,
        sensitive: Keyword.get(opts, :sensitive, false)
    end
  end

  @doc false
  @spec native_kind() :: atom()

  def native_kind, do: @native_kind

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @doc false
  @spec cast(term()) :: {:ok, String.t()} | {:error, {:invalid_string, String.t()}}

  # Невалидный UTF-8 проходил бы дальше и уезжал в БД и JSON: `String.trim/1` его не роняет,
  # `Regex.match?/2` просто отвечает false, а `re:` объявлен не у каждого Prim.
  def cast(value) when is_binary(value) do
    if String.valid?(value),
      do: {:ok, value},
      else: {:error, {:invalid_string, "невалидная UTF-8 строка"}}
  end

  def cast(_), do: {:error, {:invalid_string, "невалидное значение"}}

  @doc false
  @spec mutate(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, {:invalid_value, String.t()}}

  def mutate(value, opts) when is_binary(value) do
    case check_sec_max_len(value, sec_max_len(opts)) do
      :ok -> {:ok, trim(value, Keyword.get(opts, :trim, true))}
      {:error, _} = err -> err
    end
  end

  # ---

  defp sec_max_len(opts) do
    max_len = Keyword.get(opts, :max_len)

    Keyword.get(opts, :sec_max_len) ||
      (max_len && max_len * @max_utf8_bytes_per_char + @sec_max_len_slack)
  end

  defp check_sec_max_len(_value, nil), do: :ok

  # Граница по байтам, а не по графемам: `String.length/1` — O(n) обход, то есть ровно та
  # работа, от которой security-лимит должен защищать.
  defp check_sec_max_len(value, sec_max_len) when is_integer(sec_max_len) do
    if byte_size(value) <= sec_max_len do
      :ok
    else
      {:error, {:invalid_value, "невалидное значение"}}
    end
  end

  defp trim(value, true), do: String.trim(value)

  defp trim(value, false), do: value
end
