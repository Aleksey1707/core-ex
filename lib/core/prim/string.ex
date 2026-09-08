defmodule Core.Prim.String do
  @moduledoc """
  Билдер string-Prim: `cast` (байтовый лимит + UTF-8) → `mutate` (trim) → `Validator.String`.

  Опции: `name:` (обязательна), `kind:`, `min_len:`, `max_len:`, `sec_max_len:`, `re:`,
  `trim:` (default `true`), `mutate:` / `validate:` (кастомные шаги), `sensitive:`.

  `sec_max_len` — граница **в байтах**, отсекающая заведомо огромный ввод до любой
  посимвольной работы; default — `max_len * 4 + 50` (4 байта на кодовую точку UTF-8 +
  запас). Prim без `max_len` обязан задать её сам: без верхней границы примитив
  принимает ввод любого размера, а по одному `min_len` / `re` вывести её не из чего.
  """

  @behaviour Core.Mutator

  alias Core.Prim
  alias Core.Validator

  use Core.Prim.Wrapper,
    label: "Prim.String",
    native_kind: :string,
    required: ~w(name)a,
    optional: ~w(kind min_len max_len sec_max_len re trim mutate validate sensitive)a

  @sec_max_len_slack 50
  @max_utf8_bytes_per_char 4

  @doc "Объявить string-Prim (`name:` + опции длины/regex)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      kind = Prim.Opts.prepare!(opts, Core.Prim.String)

      type_opts = Keyword.take(opts, ~w(min_len max_len re)a)

      pipeline_opts = [
        sec_max_len: Core.Prim.String.sec_max_len(opts),
        trim: Keyword.get(opts, :trim, true)
      ]

      use Prim,
        cast: &Core.Prim.String.cast/2,
        mutate: &Core.Prim.String.mutate/2,
        validate: {Validator.String, type_opts},
        custom_mutate: Keyword.get(opts, :mutate),
        custom_validate: Keyword.get(opts, :validate),
        name: Keyword.fetch!(opts, :name),
        kind: kind,
        type_opts: type_opts,
        pipeline_opts: pipeline_opts,
        sensitive: Keyword.get(opts, :sensitive, false),
        value_type: String.t()
    end
  end

  @doc "Проверить значения опций билдера на этапе компиляции."
  @spec validate_opts!(keyword()) :: :ok

  def validate_opts!(opts) do
    Prim.Opts.non_neg_integer!(opts, ~w(min_len max_len sec_max_len)a, label())
    Prim.Opts.int_bounds!(opts, :min_len, :max_len, label())
    Prim.Opts.regex!(opts, :re, label())
    Prim.Opts.boolean!(opts, ~w(trim sensitive)a, label())
    require_byte_limit!(opts)
  end

  @doc "Байтовая граница Prim: явная `sec_max_len:` либо выведенная из `max_len:`."
  @spec sec_max_len(keyword()) :: pos_integer()

  def sec_max_len(opts) do
    Keyword.get(opts, :sec_max_len) ||
      Keyword.fetch!(opts, :max_len) * @max_utf8_bytes_per_char + @sec_max_len_slack
  end

  @doc false
  @spec cast(term(), keyword()) :: {:ok, String.t()} | {:error, {:invalid_string, String.t()}}

  # Невалидный UTF-8 иначе уезжал бы в БД и JSON: `String.trim/1` его не роняет,
  # `Regex.match?/2` просто отвечает false, а `re:` объявлен не у каждого Prim.
  def cast(value, opts) when is_binary(value) do
    with :ok <- Prim.check_byte_limit(value, Keyword.get(opts, :sec_max_len), :invalid_string) do
      if String.valid?(value),
        do: {:ok, value},
        else: {:error, {:invalid_string, "невалидная UTF-8 строка"}}
    end
  end

  def cast(_value, _opts), do: {:error, {:invalid_string, "невалидное значение"}}

  @doc false
  @spec mutate(String.t(), keyword()) :: {:ok, String.t()}

  @impl true
  def mutate(value, opts) when is_binary(value) do
    {:ok, trim(value, Keyword.get(opts, :trim, true))}
  end

  # ---

  defp require_byte_limit!(opts) do
    if is_nil(Keyword.get(opts, :max_len)) and is_nil(Keyword.get(opts, :sec_max_len)) do
      raise CompileError,
        description:
          "#{label()}: нужен max_len или sec_max_len — без верхней границы " <>
            "Prim принимает строку любого размера"
    end

    :ok
  end

  defp trim(value, true), do: String.trim(value)

  defp trim(value, false), do: value
end
