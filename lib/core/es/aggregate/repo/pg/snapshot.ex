defmodule Core.Es.Aggregate.Repo.Pg.Snapshot do
  @moduledoc """
  Снапшоты write-репозитория event-sourced агрегата (`use Core.Es.Aggregate.Repo.Pg, snapshot:`):
  опция — на компиляции; маркер, свёртка от снапшота и его запись — в рантайме.

  Снапшот — кэш свёртки, а не wire: состояние хранится `:erlang.term_to_binary/1` в
  `es_snapshots` (`Core.Es.Migration`) и читается `binary_to_term(bin, [:safe])` без кодека и без
  `new/1` Prim. Устаревшую форму состояния отсекает маркер, битую — сверка ключей struct с
  `defstruct`, `id` и версии — с адресом строки.
  """

  import Ecto.Query, only: [from: 2]

  alias Core.Es
  alias Core.Es.Aggregate.Repo.Pg.Snapshot.Schema
  alias Core.Helper
  alias Core.Helper.AfterCommit
  alias Core.Telemetry
  alias Core.Version

  require Logger

  @required_keys ~w(every)a
  @optional_keys ~w(version)a
  @default_version 1

  @typedoc "Настройка снапшотов репозитория."
  @type t :: %{every: pos_integer(), version: integer()}

  @doc "Опция `snapshot:` → настройка снапшотов; неверная опция — `CompileError`."
  @spec opts!(term(), String.t()) :: t()

  def opts!(opts, label) when is_binary(label) do
    label = "#{label}: snapshot"
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, label)

    %{
      every: every!(Keyword.fetch!(opts, :every), label),
      version: version!(Keyword.get(opts, :version, @default_version), label)
    }
  end

  # ---

  defp every!(every, _label) when is_integer(every) and every > 0, do: every

  defp every!(every, label) do
    raise CompileError,
      description: "#{label}: every: ожидается целое больше нуля, получено #{inspect(every)}"
  end

  defp version!(version, _label) when is_integer(version), do: version

  defp version!(version, label) do
    raise CompileError,
      description: "#{label}: version: ожидается целое, получено #{inspect(version)}"
  end

  @doc """
  Маркер снапшотов репозитория: md5 загруженных модулей агрегата, кодека событий и событий
  кодека плюс `version:`.

  Считается по коду, который исполняется сейчас, а не на компиляции репозитория: правка любого из
  этих модулей меняет маркер без пересборки репозитория.
  """
  @spec marker(map()) :: String.t()

  def marker(%{aggregate: aggregate, event_codec: event_codec, snapshot: %{version: version}}) do
    [aggregate, event_codec | Enum.sort(event_codec.__es_mods__())]
    |> Enum.map(& &1.module_info(:md5))
    |> then(&:erlang.md5([&1, Integer.to_string(version)]))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Свернуть события хвоста `events` от снапшота `{version, binary}` потока состояния `initial`.

  Отказ снапшота — `:rejected` и `Logger.warning`: `binary` не читается
  `binary_to_term(bin, [:safe])`, ключи struct не совпали с `defstruct` агрегата, `id` или версия
  — с адресом снапшота, `fold/2` хвоста поднял исключение.
  """
  @spec fold(map(), struct(), {pos_integer(), binary()}, [Es.Event.t()]) ::
          {:ok, struct()} | :rejected

  def fold(cfg, %{id: id} = _initial, {version, binary}, events)
      when is_integer(version) and is_binary(binary) and is_list(events) do
    with {:error, reason} <- fold_snapshot(cfg.aggregate, id, {version, binary}, events) do
      Logger.warning(
        "снапшот агрегата отвергнут: type=#{cfg.type} aggregate_id=#{cfg.codec.dump(id)} " <>
          "aggregate_version=#{version} reason=#{reason(reason)}"
      )

      :rejected
    end
  end

  # ---

  defp fold_snapshot(aggregate, id, {version, binary}, events) do
    with {:ok, state} <- decode(binary),
         :ok <- verify_state(state, aggregate, id, version),
         do: fold_events(aggregate, state, events)
  end

  defp decode(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> {:error, :decode}
  end

  defp verify_state(
         %{__struct__: aggregate, id: id, version: %Version{} = version} = state,
         aggregate,
         id,
         value
       ) do
    if Version.value(version) == value and keys(state) == keys(struct(aggregate)),
      do: :ok,
      else: {:error, :struct}
  end

  defp verify_state(_state, _aggregate, _id, _value), do: {:error, :struct}

  defp keys(state), do: Enum.sort(Map.keys(state))

  defp fold_events(aggregate, state, events) do
    {:ok, aggregate.fold(state, events)}
  rescue
    exception -> {:error, {:fold, exception.__struct__}}
  end

  defp reason({:fold, exception}), do: "fold error=#{inspect(exception)}"
  defp reason(reason), do: Atom.to_string(reason)

  @doc """
  Записать снапшоты состояний `states` одним upsert после commit
  (`Core.Helper.AfterCommit.register/1`), вне транзакции — сразу.

  Строка потока перезаписывается, только если её маркер другой или версия ниже. Отказ записи —
  `Logger.warning`, а не исключение: снапшот — кэш. `[]` — `:ok` без запроса.
  """
  @spec write(map(), [struct()]) :: :ok

  def write(cfg, states)

  def write(_cfg, []), do: :ok

  def write(cfg, [_ | _] = states), do: AfterCommit.register(fn -> upsert(cfg, states) end)

  # ---

  defp upsert(cfg, states) do
    start = System.monotonic_time()
    {result, rows} = log_write(insert(cfg, states), cfg, states)

    :telemetry.execute(
      Telemetry.event([:es, :snapshot, :write]),
      %{duration: System.monotonic_time() - start, rows: rows},
      %{type: cfg.type, result: result}
    )
  end

  defp insert(cfg, states) do
    {:ok, insert_all!(cfg, states)}
  rescue
    exception -> {:error, exception}
  end

  defp insert_all!(cfg, states) do
    marker = marker(cfg)

    {rows, nil} =
      cfg.dao.insert_all(Schema, Enum.map(states, &row(cfg, marker, &1)),
        on_conflict: on_conflict(),
        conflict_target: [:aggregate_type, :aggregate_id]
      )

    rows
  end

  defp row(cfg, marker, state) do
    %{
      aggregate_type: cfg.type,
      aggregate_id: cfg.codec.dump(state.id),
      aggregate_version: Version.value(state.version),
      marker: marker,
      state: :erlang.term_to_binary(state)
    }
  end

  # Конкурентный писатель старой версии не перетирает новую; другой маркер — снапшот другого кода.
  defp on_conflict do
    from(s in Schema,
      where:
        s.marker != fragment("EXCLUDED.marker") or
          s.aggregate_version < fragment("EXCLUDED.aggregate_version"),
      update: [
        set: [
          aggregate_version: fragment("EXCLUDED.aggregate_version"),
          marker: fragment("EXCLUDED.marker"),
          state: fragment("EXCLUDED.state"),
          updated_at: fragment("now()")
        ]
      ]
    )
  end

  defp log_write({:ok, rows}, cfg, _states) do
    Logger.debug("снапшоты агрегата записаны: type=#{cfg.type} rows=#{rows}")
    {:ok, rows}
  end

  defp log_write({:error, exception}, cfg, states) do
    Logger.warning(
      "снапшоты агрегата не записаны: type=#{cfg.type} rows=#{length(states)} " <>
        "error=#{Exception.message(exception)}"
    )

    {:error, 0}
  end
end
