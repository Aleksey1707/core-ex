defmodule Core.Prim.DateTime do
  @moduledoc """
  Билдер datetime-Prim поверх `DateTime`.

  Опции: `name:` (обязательна), `kind:`, `after:` / `before:`, `precision:`
  (`:second` — default, `:millisecond`, `:microsecond`), `tz:`, `mutate:` / `validate:`,
  `sensitive:`. Дополнительно генерирует `now/0`, `now!/0` и `from/1`, `from!/1`
  (конверсия из другого datetime-Prim).
  """

  alias Core.Config
  alias Core.Error
  alias Core.Helper
  alias Core.Prim
  alias Core.Result
  alias Core.Validator

  @native_kind :datetime
  @required_keys ~w(name)a
  @optional_keys ~w(kind after before tz precision mutate validate sensitive)a
  @precisions ~w(second millisecond microsecond)a

  @doc "Объявить datetime-Prim (`name:` + опции tz/precision/bounds)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(
        opts,
        Core.Prim.DateTime.required_keys(),
        Core.Prim.DateTime.optional_keys(),
        "Prim.DateTime"
      )

      native = Core.Prim.DateTime.native_kind()
      kind = Keyword.get(opts, :kind, native)
      Prim.validate_kind!(native, kind)

      precision = Keyword.get(opts, :precision, :second)
      Core.Prim.DateTime.validate_precision!(precision)

      type_opts = Keyword.take(opts, ~w(after before tz precision)a)

      use Prim,
        cast: &Core.Prim.DateTime.cast/1,
        mutate: &Core.Prim.DateTime.mutate/2,
        validate: {Validator.DateTime, type_opts},
        custom_mutate: Keyword.get(opts, :mutate),
        custom_validate: Keyword.get(opts, :validate),
        name: Keyword.fetch!(opts, :name),
        kind: kind,
        type_opts: type_opts,
        sensitive: Keyword.get(opts, :sensitive, false)

      @tz Keyword.get(type_opts, :tz)

      @doc "Текущее время в tz модуля/конфига."
      @spec now() :: {:ok, t()} | {:error, Error.t()}

      def now do
        tz = @tz || Core.Config.tz()

        case DateTime.now(tz) do
          {:ok, dt} ->
            new(dt)

          {:error, _} ->
            {:error,
             Prim.wrap_error(
               __MODULE__,
               name(),
               :invalid_datetime,
               "невалидное значение",
               tz
             )}
        end
      end

      @doc "Текущее время; при ошибке — raise."
      @spec now!() :: t()

      def now!, do: Result.unwrap!(now())

      @doc "Собрать из другого datetime-Prim (полный pipeline целевого `new/1`)."
      @spec from(term()) :: {:ok, t()} | {:error, Error.t()}

      def from(%mod{value: %DateTime{}} = prim) when is_atom(mod) do
        if Prim.prim?(mod),
          do: new(mod.value(prim)),
          else:
            {:error,
             Prim.wrap_error(
               __MODULE__,
               name(),
               :invalid_datetime,
               "невалидное значение",
               prim
             )}
      end

      @doc "Собрать из другого datetime-Prim; при ошибке — raise."
      @spec from!(term()) :: t()

      def from!(prim), do: Result.unwrap!(from(prim))
    end
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @doc false
  @spec native_kind() :: atom()

  def native_kind, do: @native_kind

  @doc false
  @spec precisions() :: [atom()]

  def precisions, do: @precisions

  @doc "Проверить `precision:` — атом как у `DateTime.truncate/2`."
  @spec validate_precision!(atom()) :: :ok

  def validate_precision!(precision) when precision in @precisions, do: :ok

  def validate_precision!(precision) do
    raise ArgumentError,
          "unknown precision: #{inspect(precision)}; expected one of #{inspect(@precisions)}"
  end

  @doc false
  @spec cast(term()) :: {:ok, DateTime.t()} | {:error, {:invalid_datetime, String.t()}}

  def cast(%DateTime{} = value), do: {:ok, value}

  def cast(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _} -> {:error, {:invalid_datetime, "невалидное значение"}}
    end
  end

  def cast(_), do: {:error, {:invalid_datetime, "невалидное значение"}}

  @doc false
  @spec mutate(DateTime.t(), keyword()) ::
          {:ok, DateTime.t()} | {:error, {:invalid_datetime, String.t()}}

  def mutate(%DateTime{} = value, opts) do
    tz = Keyword.get(opts, :tz) || Config.tz()
    precision = Keyword.get(opts, :precision, :second)

    case DateTime.shift_zone(value, tz) do
      {:ok, shifted} ->
        truncated = DateTime.truncate(shifted, precision)
        {:ok, put_precision(truncated, precision)}

      {:error, _} ->
        {:error, {:invalid_datetime, "невалидное значение"}}
    end
  end

  # ---

  defp put_precision(%DateTime{microsecond: {us, _}} = dt, :millisecond),
    do: %{dt | microsecond: {us, 3}}

  defp put_precision(%DateTime{microsecond: {us, _}} = dt, :microsecond),
    do: %{dt | microsecond: {us, 6}}

  defp put_precision(%DateTime{} = dt, :second), do: dt
end
