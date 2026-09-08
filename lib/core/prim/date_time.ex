defmodule Core.Prim.DateTime do
  @moduledoc """
  Билдер datetime-Prim поверх `DateTime`.

  Опции: `name:` (обязательна), `kind:`, `after:` / `before:`, `precision:`
  (`:second` — default, `:millisecond`, `:microsecond`), `tz:`, `mutate:` / `validate:`,
  `sensitive:`. Дополнительно генерирует `now/0`, `now!/0` и `from/1`, `from!/1`
  (конверсия из другого datetime-Prim).
  """

  @behaviour Core.Mutator

  alias Core.Config
  alias Core.Error
  alias Core.Prim
  alias Core.Result
  alias Core.Validator

  use Core.Prim.Wrapper,
    label: "Prim.DateTime",
    native_kind: :datetime,
    required: ~w(name)a,
    optional: ~w(kind after before tz precision mutate validate sensitive)a

  @precisions ~w(second millisecond microsecond)a

  @doc "Объявить datetime-Prim (`name:` + опции tz/precision/bounds)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      kind = Prim.Opts.prepare!(opts, Core.Prim.DateTime)

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
        sensitive: Keyword.get(opts, :sensitive, false),
        value_type: DateTime.t()

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
  @spec precisions() :: [atom()]

  def precisions, do: @precisions

  @doc "Проверить значения опций билдера на этапе компиляции."
  @spec validate_opts!(keyword()) :: :ok

  def validate_opts!(opts) do
    Prim.Opts.struct_bounds!(opts, :after, :before, DateTime, label())
    Prim.Opts.tz!(opts, :tz, label())
    Prim.Opts.boolean!(opts, ~w(sensitive)a, label())
    validate_precision!(Keyword.get(opts, :precision, :second))
  end

  @doc "Проверить `precision:` — атом как у `DateTime.truncate/2`."
  @spec validate_precision!(atom()) :: :ok

  def validate_precision!(precision) when precision in @precisions, do: :ok

  def validate_precision!(precision) do
    raise ArgumentError,
          "неизвестное precision: #{inspect(precision)}; допустимые: #{inspect(@precisions)}"
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

  @impl true
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
