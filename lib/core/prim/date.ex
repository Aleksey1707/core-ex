defmodule Core.Prim.Date do
  @moduledoc """
  Билдер date-Prim поверх `Date` (дата без времени).

  Опции: `name:` (обязательна), `kind:`, `after:` / `before:`, `tz:`, `mutate:` /
  `validate:`, `sensitive:`, `personal:`. Дополнительно генерирует `today/0`, `today!/0` и
  `from/1`, `from!/1` (из date- или datetime-Prim, с приведением в `tz:`).

  `Result` у `today/0` несёт только доменные отказы `new/1`, включая bounds `after:` / `before:`.
  Неверный `tz:` — `ArgumentError` от `DateTime.shift_zone!/2`: ошибку конфигурации отсекает
  `Core.Config.validate!/0` на старте.

  Опции-выражения (`docs/rules/20-agreements.md`, «Опции `use`»): `name:`, `mutate:`, `validate:` — проверяются в
  теле модуля; остальные опции — литералы.
  """

  alias Core.Prim
  alias Core.Result

  use Core.Prim.Wrapper,
    label: "Prim.Date",
    native_kind: :date,
    optional: ~w(after before tz)a

  @doc "Объявить date-Prim (`name:` + опции tz/bounds)."
  defmacro __using__(opts) do
    opts = Prim.Opts.prepare!(opts, __CALLER__, __MODULE__)
    bounds = Macro.escape(Keyword.take(opts, ~w(after before)a))
    type_opts = Macro.escape(Keyword.take(opts, ~w(after before tz)a))

    base_opts =
      Prim.Wrapper.base_opts(opts, label()) ++
        [
          cast: quote(do: &Core.Prim.Date.cast/1),
          validate: quote(do: {Core.Validator.Date, unquote(bounds)}),
          type_opts: type_opts,
          value_type: quote(do: Date.t())
        ]

    quote do
      use Core.Prim, unquote(base_opts)

      @tz unquote(Keyword.get(opts, :tz))

      @doc """
      Сегодняшняя дата доменного времени (`Core.Clock`) в tz модуля/конфига.

      `Result` несёт только доменные отказы `new/1` (включая bounds `after:` / `before:`).
      Неверный `tz:` — `ArgumentError` от `DateTime.shift_zone!/2`.
      """
      @spec today() :: Core.Result.t(t())

      def today do
        tz = @tz || Core.Config.tz()

        new(DateTime.to_date(DateTime.shift_zone!(Core.Clock.now(), tz)))
      end

      @doc "Сегодняшняя дата; при отказе `new/1` — raise."
      @spec today!() :: t()

      def today! do
        %__MODULE__{} = prim = Result.unwrap!(today())
        prim
      end

      @doc """
      Собрать из другого date/datetime-Prim (полный pipeline целевого `new/1`).

      Datetime приводится к дате в tz модуля/конфига.
      """
      @spec from(term()) :: Core.Result.t(t())

      def from(%mod{value: value} = prim)
          when is_atom(mod) and (is_struct(value, Date) or is_struct(value, DateTime)) do
        with {:ok, date} <-
               Core.Prim.Date.extract(
                 __MODULE__,
                 name(),
                 mod,
                 prim,
                 @tz || Core.Config.tz()
               ) do
          new(date)
        end
      end

      @doc "Собрать из другого date/datetime-Prim; при ошибке — raise."
      @spec from!(term()) :: t()

      def from!(prim), do: Result.unwrap!(from(prim))
    end
  end

  @doc "Проверить значения опций-литералов билдера при раскрытии `use`."
  @spec validate_opts!(keyword()) :: :ok

  def validate_opts!(opts) do
    Prim.Opts.struct_bounds!(opts, :after, :before, Date, label())
    Prim.Opts.tz!(opts, :tz, label())
  end

  @doc false
  @spec cast(term()) :: Result.t(Date.t(), {:invalid_date, String.t()})

  def cast(%Date{} = value), do: {:ok, value}

  def cast(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> invalid()
    end
  end

  def cast(_), do: invalid()

  @doc "Достать `%Date{}` из date/datetime-Prim; datetime приводится к дате в `tz`."
  @spec extract(module(), String.t(), module(), struct(), String.t()) ::
          Result.t(Date.t())

  def extract(target, name, mod, prim, tz)
      when is_atom(target) and is_binary(name) and is_atom(mod) and is_struct(prim) and
             is_binary(tz) do
    with :ok <- ensure_prim(mod),
         {:ok, date} <- to_date(mod.value(prim), tz) do
      {:ok, date}
    else
      {:error, {code, detail}} ->
        {:error, Prim.wrap_error(target, name, code, detail, prim)}
    end
  end

  # ---

  defp ensure_prim(mod) do
    if Prim.prim?(mod), do: :ok, else: invalid()
  end

  defp to_date(%Date{} = date, _tz), do: {:ok, date}

  defp to_date(%DateTime{} = dt, tz) do
    case DateTime.shift_zone(dt, tz) do
      {:ok, shifted} -> {:ok, DateTime.to_date(shifted)}
      {:error, _} -> invalid()
    end
  end

  defp invalid, do: {:error, {:invalid_date, "невалидное значение"}}
end
