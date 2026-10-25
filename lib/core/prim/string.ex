defmodule Core.Prim.String do
  @moduledoc """
  Билдер string-Prim: `cast` (байтовый лимит + UTF-8) → `mutate` (trim) → `Validator.String`.

  Опции: `name:` (обязательна), `kind:`, `min_len:`, `max_len:`, `sec_max_len:`, `re:`,
  `trim:` (default `true`), `mutate:` / `validate:` (кастомные шаги), `sensitive:`, `personal:`.

  `sec_max_len` — граница **в байтах**, отсекающая заведомо огромный ввод до любой
  посимвольной работы; default — `max_len * 4 + 50` (4 байта на кодовую точку UTF-8 +
  запас). Prim без `max_len` обязан задать её сам: без верхней границы примитив
  принимает ввод любого размера, а по одному `min_len` / `re` вывести её не из чего.

  Опции-выражения (`docs/rules/20-agreements.md`, «Опции `use`»): `name:`, `mutate:`, `validate:`,
  `max_len:`, `re:` — проверяются в теле модуля;
  остальные опции — литералы.
  """

  @behaviour Core.Mutator

  alias Core.Helper
  alias Core.Prim
  alias Core.Result

  use Core.Prim.Wrapper,
    label: "Prim.String",
    native_kind: :string,
    optional: ~w(min_len max_len sec_max_len re trim)a,
    expression: ~w(max_len re)a

  @sec_max_len_slack 50
  @max_utf8_bytes_per_char 4
  @type_keys ~w(min_len max_len re)a

  @doc "Объявить string-Prim (`name:` + опции длины/regex)."
  defmacro __using__(opts) do
    opts = Prim.Opts.prepare!(opts, __CALLER__, __MODULE__)
    type_opts = Prim.Opts.quoted(Keyword.take(opts, @type_keys), expression_keys())

    pipeline_opts =
      quote do
        [
          sec_max_len: Core.Prim.String.sec_max_len(unquote(Keyword.take(opts, [:sec_max_len])) ++ @prim_type_opts),
          trim: unquote(Keyword.get(opts, :trim, true))
        ]
      end

    base_opts =
      Prim.Wrapper.base_opts(opts, label()) ++
        [
          cast: quote(do: &Core.Prim.String.cast/2),
          mutate: quote(do: &Core.Prim.String.mutate/2),
          validate: quote(do: {Core.Validator.String, @prim_type_opts}),
          type_opts: quote(do: @prim_type_opts),
          pipeline_opts: pipeline_opts,
          value_type: quote(do: String.t())
        ]

    quote do
      @prim_type_opts Core.Prim.String.type_opts!(unquote(type_opts))

      use Core.Prim, unquote(base_opts)
    end
  end

  @doc "Проверить значения опций-литералов билдера при раскрытии `use`."
  @spec validate_opts!(keyword()) :: :ok

  def validate_opts!(opts) do
    Prim.Opts.non_neg_integer!(opts, ~w(min_len sec_max_len)a, label())
    Prim.Opts.boolean!(opts, ~w(trim)a, label())
    require_byte_limit!(opts)
  end

  @doc false
  @spec type_opts!(keyword()) :: keyword()

  # Опции типа с вычисленными опциями-выражениями `max_len:` / `re:` — проверка в теле модуля.
  def type_opts!(type_opts) do
    Prim.Opts.non_neg_integer!(type_opts, ~w(max_len)a, label())
    Prim.Opts.int_bounds!(type_opts, :min_len, :max_len, label())
    Prim.Opts.regex!(type_opts, :re, label())

    type_opts
  end

  @doc "Байтовая граница Prim: явная `sec_max_len:` либо выведенная из `max_len:`."
  @spec sec_max_len(keyword()) :: pos_integer()

  def sec_max_len(type_opts) do
    Keyword.get(type_opts, :sec_max_len) ||
      Keyword.fetch!(type_opts, :max_len) * @max_utf8_bytes_per_char + @sec_max_len_slack
  end

  @doc false
  @spec cast(term(), keyword()) :: Result.t(String.t(), {:invalid_string, String.t()})

  # Невалидный UTF-8 иначе уезжал бы в БД и JSON: `String.trim/1` его не роняет,
  # `Regex.match?/2` просто отвечает false, а `re:` объявлен не у каждого Prim.
  def cast(value, pipeline_opts) when is_binary(value) do
    with :ok <- Prim.check_byte_limit(value, Keyword.get(pipeline_opts, :sec_max_len), :invalid_string) do
      if String.valid?(value),
        do: {:ok, value},
        else: {:error, {:invalid_string, "невалидная UTF-8 строка"}}
    end
  end

  def cast(_value, _pipeline_opts), do: {:error, {:invalid_string, "невалидное значение"}}

  @doc false
  @spec mutate(String.t(), keyword()) :: {:ok, String.t()}

  @impl true
  def mutate(value, opts) when is_binary(value) do
    {:ok, trim(value, Keyword.get(opts, :trim, true))}
  end

  # ---

  defp require_byte_limit!(opts) do
    if is_nil(Keyword.get(opts, :max_len)) and is_nil(Keyword.get(opts, :sec_max_len)) do
      Helper.Opts.reject!(
        label(),
        "нужен max_len или sec_max_len — без верхней границы Prim принимает строку любого размера"
      )
    end

    :ok
  end

  defp trim(value, true), do: String.trim(value)
  defp trim(value, false), do: value
end
