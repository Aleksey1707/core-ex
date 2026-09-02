defmodule Core.Codec do
  @moduledoc """
  Билдер профилей сериализации доменных Prim.

  Приоритет dump: `dump(%Mod{})` → `dump_kind(prim, kind)` → builtin по kind.
  Приоритет load: `load(mod, raw)` → `load_kind(mod, raw, kind)` → builtin → `mod.new/1`.

  Kind `:composite` (`Prim.Compose`): dump → `dump(value)` (рекурсия до leaf);
  load → `load(base, raw)` + `mod.new(inner)`. Wire-формат совпадает с базовым Prim.

  Профиль влияет только на dump. Load формат-агностичен: приведение делает `cast`
  примитива (`Prim.UUID` — full/hex/urn, `Prim.DateTime` — `%DateTime{}` и ISO8601,
  `Prim.Decimal` — struct/int/float/string). Симметрия dump↔load не гарантируется.

  Опции datetime разделены на две оси: `datetime:` — форма (`:datetime` → `%DateTime{}`,
  `:iso8601` → строка), `datetime_tz:` — `:keep`, `:app` (tz приложения из
  `Core.Config.tz/0`, резолв в рантайме) или IANA-зона для `shift_zone!/2`.

  Опция `date:` — форма даты без времени (`:date` → `%Date{}`, `:iso8601` → строка);
  необязательна, по умолчанию `:date`.

  `dump_raw(kind, raw)` — тот же формат для значения **без** Prim-обёртки (read-модели,
  `<Aggregate>View.Codec`). Builtin `dump_kind` реализован через него, поэтому формат
  Prim-пути и раw-пути не расходится даже при `defoverridable`.

  `dump_raw_as(mod, raw)` — то же, но формат берётся у **конкретного Prim**: kind плюс его
  `__domain_type_opts__/0` (tz и precision у datetime). Одного kind мало: значение из
  колонки `utc_datetime_usec` отдало бы дробные секунды там, где агрегатный путь через
  Prim с `precision: :second` их обрезает. Операция тотальна — read-путь не валидирует:
  `nil` и неприводимое значение проходят как есть.
  """

  alias Core.Config
  alias Core.Error
  alias Core.Helper
  alias Core.Prim

  @uuid_fmts ~w(full hex urn)a
  @datetime_fmts ~w(datetime iso8601)a
  @date_fmts ~w(date iso8601)a
  @decimal_fmts ~w(decimal string)a

  @allowed_fmts %{
    uuid: @uuid_fmts,
    datetime: @datetime_fmts,
    date: @date_fmts,
    decimal: @decimal_fmts
  }

  @default_fmts %{date: :date}

  @callback dump(struct()) :: term()
  @callback dump_kind(struct(), atom()) :: term()
  @callback dump_raw(atom(), term()) :: term()
  @callback dump_raw_as(module(), term()) :: term()
  @callback load(module(), term()) :: {:ok, term()} | {:error, Error.t()}
  @callback load_kind(module(), term(), atom()) :: {:ok, term()} | {:error, Error.t()}
  @callback load!(module(), term()) :: term()

  @optional_callbacks dump_kind: 2, load_kind: 3

  @doc "Достать value из Prim-struct."
  @spec value(%{__struct__: module(), value: term()}) :: term()

  def value(%_{value: value}), do: value

  @doc false
  @spec validate_profile_opts!(keyword()) :: :ok

  def validate_profile_opts!(opts) do
    Enum.each(@allowed_fmts, fn {key, allowed} ->
      value = fetch_fmt(opts, key)

      if value not in allowed,
        do: raise(ArgumentError, "unknown #{key}: #{inspect(value)}")
    end)

    validate_datetime_tz!(Keyword.fetch!(opts, :datetime_tz))
  end

  @doc false
  @spec default_fmt(atom()) :: atom()

  def default_fmt(key) when is_map_key(@default_fmts, key), do: Map.fetch!(@default_fmts, key)

  @doc false
  @spec dump_uuid(String.t(), atom()) :: String.t()

  def dump_uuid(uuid, fmt) when is_binary(uuid), do: Prim.UUID.format(uuid, fmt)

  @doc false
  @spec dump_datetime(DateTime.t(), atom(), :keep | :app | String.t()) ::
          DateTime.t() | String.t()

  def dump_datetime(%DateTime{} = dt, fmt, tz) do
    dt
    |> shift_tz(tz)
    |> to_datetime_fmt(fmt)
  end

  @doc false
  @spec dump_date(Date.t(), atom()) :: Date.t() | String.t()

  def dump_date(%Date{} = value, :date), do: value
  def dump_date(%Date{} = value, :iso8601), do: Date.to_iso8601(value)

  @doc false
  @spec dump_decimal(Decimal.t(), atom()) :: Decimal.t() | String.t()

  def dump_decimal(%Decimal{} = value, :decimal), do: value
  def dump_decimal(%Decimal{} = value, :string), do: Decimal.to_string(value)

  @doc """
  Dump raw-значения в формате Prim `mod`: kind и опции типа берутся у самого Prim.

  Leaf-модуль ищется рекурсивно через `__domain_base__/0` (`Prim.Compose`), значение
  приводится тем же `cast`/`mutate`, что и в конвейере Prim — поэтому datetime попадает
  в tz и precision своего Prim, а не остаётся в форме, записанной в колонку.

  Тотальна: `nil`, не-Prim модуль, неприводимое значение и kind, для которого у профиля
  нет `dump_raw/2` (кастомный, `:string`, `:integer`), возвращаются как есть.
  """
  @spec dump_raw_as(module(), term(), module()) :: term()

  def dump_raw_as(_mod, nil, _profile), do: nil

  def dump_raw_as(mod, value, profile) when is_atom(mod) and is_atom(profile) do
    case leaf_prim(mod) do
      nil -> value
      leaf -> dump_leaf(leaf, value, profile)
    end
  end

  @doc """
  Builtin load: `mod.new/1` (cast Prim принимает допустимые wire-формы).

  Кастомный `kind` обслуживается тем же `mod.new/1`: load формат-агностичен, приведение
  делает сам примитив. Профиль может переопределить `load_kind/3`.
  """
  @spec load_builtin(module(), term(), atom()) :: {:ok, term()} | {:error, Error.t()}

  def load_builtin(mod, raw, kind) when is_atom(mod) and is_atom(kind) do
    mod.new(raw)
  end

  @doc """
  Ошибка dump для kind, который профиль не обслуживает.

  Кастомный `kind` (не из `Prim.native_kinds/0`) допустим, но профиль обязан объявить
  для него `dump/1` или `dump_kind/2` — иначе неясно, в какой wire-формат его писать.
  """
  @spec unsupported_kind!(module(), struct(), atom()) :: no_return()

  def unsupported_kind!(profile, prim, kind) do
    raise ArgumentError,
          "#{inspect(profile)}: нет правила dump для kind #{inspect(kind)} " <>
            "(#{inspect(prim.__struct__)}); объявите dump/1 или dump_kind/2 в профиле"
  end

  @doc "Load композита: `load(base, raw)` → `mod.new(inner)`."
  @spec load_composite(module(), term(), module()) :: {:ok, term()} | {:error, Error.t()}

  def load_composite(mod, raw, codec) when is_atom(mod) and is_atom(codec) do
    with {:ok, inner} <- codec.load(mod.__domain_base__(), raw), do: mod.new(inner)
  end

  @doc "Объявить Prim-профиль кодека (`uuid` / `datetime` / `datetime_tz` / `decimal`)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(
        opts,
        ~w(uuid datetime datetime_tz decimal)a,
        ~w(date)a,
        "Codec"
      )

      Core.Codec.validate_profile_opts!(opts)

      @behaviour Core.Codec

      @codec_uuid Keyword.fetch!(opts, :uuid)
      @codec_datetime Keyword.fetch!(opts, :datetime)
      @codec_datetime_tz Keyword.fetch!(opts, :datetime_tz)
      @codec_date Keyword.get(opts, :date, Core.Codec.default_fmt(:date))
      @codec_decimal Keyword.fetch!(opts, :decimal)

      @doc "Dump Prim по kind (builtin-форматы профиля)."
      @impl true
      def dump_kind(prim, kind) when kind in ~w(uuid datetime date decimal)a do
        dump_raw(kind, Core.Codec.value(prim))
      end

      def dump_kind(prim, kind) when kind in ~w(integer string)a do
        Core.Codec.value(prim)
      end

      def dump_kind(prim, :composite) do
        dump(Core.Codec.value(prim))
      end

      def dump_kind(prim, kind) do
        Core.Codec.unsupported_kind!(__MODULE__, prim, kind)
      end

      @doc """
      Dump raw-значения по kind — в том же формате, что и Prim этого kind.

      Для потребителей, у которых значение уже без Prim-обёртки: read-модели и
      dump-only плагины представлений (`<Aggregate>View.Codec`).

      Домен — форматируемые kinds: `:uuid`, `:datetime`, `:date`, `:decimal`.
      `:integer` / `:string` уже в wire-форме и сюда не передаются; кастомный kind
      профиль добавляет своей клоузой (`defoverridable`).
      """
      @impl true
      def dump_raw(:uuid, value), do: Core.Codec.dump_uuid(value, @codec_uuid)

      def dump_raw(:datetime, value) do
        Core.Codec.dump_datetime(value, @codec_datetime, @codec_datetime_tz)
      end

      def dump_raw(:date, value), do: Core.Codec.dump_date(value, @codec_date)

      def dump_raw(:decimal, value), do: Core.Codec.dump_decimal(value, @codec_decimal)

      @doc """
      Dump raw-значения в формате Prim `mod`: kind и опции типа берутся у самого Prim.

      Для read-моделей, где значение лежит без Prim-обёртки, но формат обязан совпасть
      с агрегатным путём (tz и precision datetime, форма uuid и decimal).
      """
      @impl true
      def dump_raw_as(mod, value) when is_atom(mod) do
        Core.Codec.dump_raw_as(mod, value, __MODULE__)
      end

      @doc "Load Prim по kind (builtin или composite)."
      @impl true
      def load_kind(mod, raw, :composite) do
        Core.Codec.load_composite(mod, raw, __MODULE__)
      end

      def load_kind(mod, raw, kind) do
        Core.Codec.load_builtin(mod, raw, kind)
      end

      defoverridable dump_kind: 2, dump_raw: 2, dump_raw_as: 2, load_kind: 3

      @before_compile Core.Codec
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    quote do
      @doc "Dump Prim: `dump_kind` по `__domain_kind__/0`."
      @impl true
      def dump(%mod{} = prim) do
        dump_kind(prim, mod.__domain_kind__())
      end

      @doc "Load Prim: `load_kind` по `__domain_kind__/0`."
      @impl true
      def load(mod, raw) when is_atom(mod) do
        load_kind(mod, raw, mod.__domain_kind__())
      end

      @doc "Load Prim; при ошибке — raise."
      @impl true
      def load!(mod, raw) when is_atom(mod) do
        Core.Result.unwrap!(load(mod, raw))
      end
    end
  end

  # ---

  defp leaf_prim(mod) do
    cond do
      not Prim.prim?(mod) -> nil
      Prim.composed?(mod) -> leaf_prim(mod.__domain_base__())
      true -> mod
    end
  end

  defp dump_leaf(leaf, value, profile) do
    kind = leaf.__domain_kind__()

    case normalize_raw(kind, value, leaf.__domain_type_opts__()) do
      {:ok, normalized} -> profile.dump_raw(kind, normalized)
      :passthrough -> value
    end
  end

  defp normalize_raw(:datetime, value, type_opts) do
    with {:ok, datetime} <- Prim.DateTime.cast(value),
         {:ok, shifted} <- Prim.DateTime.mutate(datetime, type_opts) do
      {:ok, shifted}
    else
      {:error, _} -> :passthrough
    end
  end

  defp normalize_raw(:date, value, _type_opts), do: normalized(Prim.Date.cast(value))
  defp normalize_raw(:uuid, value, _type_opts), do: normalized(Prim.UUID.cast(value))
  defp normalize_raw(:decimal, value, _type_opts), do: normalized(Prim.Decimal.cast(value))
  defp normalize_raw(_kind, _value, _type_opts), do: :passthrough

  defp normalized({:ok, value}), do: {:ok, value}
  defp normalized({:error, _}), do: :passthrough

  defp fetch_fmt(opts, key) when is_map_key(@default_fmts, key) do
    Keyword.get(opts, key, Map.fetch!(@default_fmts, key))
  end

  defp fetch_fmt(opts, key), do: Keyword.fetch!(opts, key)

  defp validate_datetime_tz!(:keep), do: :ok
  defp validate_datetime_tz!(:app), do: :ok

  # tz-база не поднимается на этапе компиляции (`ensure_all_started(:tzdata)` тянул бы
  # чтение/скачивание базы внутрь компилятора): если она уже доступна — зона проверяется
  # полностью, иначе только форма имени, а неизвестная зона всплывёт на первом dump.
  defp validate_datetime_tz!(tz) when is_binary(tz) do
    case DateTime.shift_zone(DateTime.utc_now(), tz) do
      {:ok, _} -> :ok
      {:error, :time_zone_not_found} -> raise ArgumentError, "unknown datetime_tz: #{inspect(tz)}"
      {:error, _no_tz_database} -> validate_tz_shape!(tz)
    end
  end

  defp validate_datetime_tz!(other) do
    raise ArgumentError,
          "datetime_tz must be :keep, :app or an IANA timezone string, got: #{inspect(other)}"
  end

  defp validate_tz_shape!(tz) do
    if Regex.match?(~r{^[A-Za-z][A-Za-z0-9+\-_]*(/[A-Za-z0-9+\-_]+)*$}, tz),
      do: :ok,
      else: raise(ArgumentError, "unknown datetime_tz: #{inspect(tz)}")
  end

  defp shift_tz(%DateTime{} = dt, :keep), do: dt
  defp shift_tz(%DateTime{} = dt, :app), do: DateTime.shift_zone!(dt, Config.tz())
  defp shift_tz(%DateTime{} = dt, tz) when is_binary(tz), do: DateTime.shift_zone!(dt, tz)

  defp to_datetime_fmt(%DateTime{} = dt, :datetime), do: dt
  defp to_datetime_fmt(%DateTime{} = dt, :iso8601), do: DateTime.to_iso8601(dt)
end
