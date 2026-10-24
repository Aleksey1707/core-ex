defmodule Core.Prim.DateTime do
  @moduledoc """
  Билдер datetime-Prim поверх `DateTime`.

  Опции: `name:` (обязательна), `kind:`, `after:` / `before:`, `precision:`
  (`:second` — default, `:millisecond`, `:microsecond`), `tz:`, `mutate:` / `validate:`,
  `sensitive:`, `personal:`. Дополнительно генерирует `now/0`, `now!/0` и `from/1`, `from!/1`
  (конверсия из другого datetime-Prim).

  Опции-выражения (`docs/rules/20-agreements.md`, «Опции `use`»): `name:`, `mutate:`, `validate:` — проверяются в
  теле модуля; остальные опции — литералы.
  """

  @behaviour Core.Mutator

  alias Core.Config
  alias Core.Error
  alias Core.Prim
  alias Core.Result

  use Core.Prim.Wrapper,
    label: "Prim.DateTime",
    native_kind: :datetime,
    optional: ~w(after before tz precision)a

  @precisions ~w(second millisecond microsecond)a

  @doc "Объявить datetime-Prim (`name:` + опции tz/precision/bounds)."
  defmacro __using__(opts) do
    opts = Prim.Opts.prepare!(opts, __CALLER__, __MODULE__)
    type_opts = Macro.escape(Keyword.take(opts, ~w(after before tz precision)a))

    base_opts =
      Prim.Wrapper.base_opts(opts, label()) ++
        [
          cast: quote(do: &Core.Prim.DateTime.cast/1),
          mutate: quote(do: &Core.Prim.DateTime.mutate/2),
          validate: quote(do: {Core.Validator.DateTime, unquote(type_opts)}),
          type_opts: type_opts,
          value_type: quote(do: DateTime.t())
        ]

    quote do
      use Core.Prim, unquote(base_opts)

      @tz unquote(Keyword.get(opts, :tz))

      @doc "Доменное «сейчас» (`Core.Clock`) в tz модуля/конфига."
      @spec now() :: Core.Result.t(t())

      def now do
        tz = @tz || Core.Config.tz()

        case DateTime.shift_zone(Core.Clock.now(), tz) do
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

      unquote(
        quote generated: true do
          def now! do
            case now() do
              {:ok, %__MODULE__{} = prim} -> prim
              {:error, %Error{} = error} -> raise Core.Exc, error
            end
          end
        end
      )

      @doc "Собрать из другого datetime-Prim (полный pipeline целевого `new/1`)."
      @spec from(term()) :: Core.Result.t(t())

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

  @doc "Проверить значения опций-литералов билдера при раскрытии `use`."
  @spec validate_opts!(keyword()) :: :ok

  def validate_opts!(opts) do
    Prim.Opts.struct_bounds!(opts, :after, :before, DateTime, label())
    Prim.Opts.tz!(opts, :tz, label())
    Prim.Opts.allowed!(opts, :precision, @precisions, label())
  end

  @doc false
  @spec cast(term()) :: Result.t(DateTime.t(), {:invalid_datetime, String.t()})

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
          Result.t(DateTime.t(), {:invalid_datetime, String.t()})

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
