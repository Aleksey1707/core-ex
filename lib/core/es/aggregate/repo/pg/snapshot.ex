defmodule Core.Es.Aggregate.Repo.Pg.Snapshot do
  @moduledoc """
  Снапшоты write-репозитория event-sourced агрегата (`use Core.Es.Aggregate.Repo.Pg, snapshot:`):
  опция — на компиляции; маркер, свёртка от снапшота и его запись — в рантайме.

  Снапшот — кэш свёртки, а не wire: состояние хранится `:erlang.term_to_binary/1` в
  `es_snapshots` (`Core.Es.Migration`) и читается `binary_to_term(bin, [:safe])` без кодека и без
  `new/1` Prim. Устаревшую форму состояния отсекает маркер, битую — сверка ключей struct с
  `defstruct`, `id` и версии — с адресом строки.

  У агрегата с ПДн в событиях (`__es_personal__/0` кодека не пуст) снапшот — одно ПДн-значение
  субъекта `aggregate_id` (ADR-0076): `term_to_binary` состояния целиком шифрует `seal` хранилища
  ключей (`Core.Es.Personal.Port`), AAD — `Core.Es.Personal.Port.address/1` над типом агрегата,
  `aggregate_id`, версией и маркером. Признак шифрованного снапшота входит в маркер.
  """

  import Ecto.Query, only: [from: 2]

  alias Core.Error
  alias Core.Es
  alias Core.Es.Aggregate.Repo.Pg.Config
  alias Core.Es.Aggregate.Repo.Pg.Snapshot.Schema
  alias Core.Es.Aggregate.Repo.Pg.Snapshot.Settings
  alias Core.Es.Personal.KeyStore
  alias Core.Es.Personal.Port
  alias Core.Helper
  alias Core.Helper.AfterCommit
  alias Core.Telemetry
  alias Core.Version

  require Logger

  @required_keys ~w(every)a
  @optional_keys ~w(version)a
  @default_version 1

  @typedoc "Снапшот потока: версия и binary состояния."
  @type stored :: {pos_integer(), binary()}

  @typedoc "Снапшот потока после расшифровки: версия и исход `open` (у нешифрованного — `{:ok, binary}`)."
  @type opened :: {pos_integer(), KeyStore.opened()}

  # ===== опции =====

  @doc """
  Опция `snapshot:` → настройка снапшотов; `plan` — ПДн-план кодека событий (`__es_personal__/0`).

  Неверная опция и ПДн-место не под `:aggregate_id` (в том числе вложенное) — `CompileError`.
  """
  @spec opts!(term(), %{optional(module()) => [Core.Es.Personal.Plan.entry()]}, String.t()) :: Settings.t()

  def opts!(opts, plan, label) when is_map(plan) and is_binary(label) do
    label = "#{label}: snapshot"
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, label)

    %Settings{
      every: every!(Keyword.fetch!(opts, :every), label),
      version: version!(Keyword.get(opts, :version, @default_version), label),
      sealed: sealed!(plan, label)
    }
  end

  # ---

  defp every!(every, _label) when is_integer(every) and every > 0, do: every

  defp every!(every, label),
    do: Helper.Opts.reject!("#{label}: every", "ожидается целое больше нуля, получено #{inspect(every)}")

  defp version!(version, _label) when is_integer(version), do: version

  defp version!(version, label),
    do: Helper.Opts.reject!("#{label}: version", "ожидается целое, получено #{inspect(version)}")

  # Снапшот — одно ПДн-значение одного субъекта: ПДн другого субъекта под ключом агрегата не
  # уничтожались бы вместе со своим ключом.
  defp sealed!(plan, label) do
    places =
      for {mod, entries} <- plan, %{path: path, subject: subject} <- entries, subject != :aggregate_id, do: {mod, path}

    case Enum.sort(places) do
      [] ->
        plan != %{}

      places ->
        Helper.Opts.reject!(
          label,
          "субъект ПДн-поля — поле нагрузки, а не :aggregate_id: " <>
            Enum.map_join(places, ", ", fn {mod, path} -> "#{inspect(mod)}.#{Enum.join(path, ".")}" end)
        )
    end
  end

  # ===== восстановление =====

  @doc """
  Маркер снапшотов репозитория: md5 загруженных модулей агрегата, кодека событий и событий
  кодека плюс `version:` и признак шифрованного снапшота.

  Считается по коду, который исполняется сейчас, а не на компиляции репозитория: правка любого из
  этих модулей меняет маркер без пересборки репозитория.
  """
  @spec marker(Config.t()) :: String.t()

  def marker(%Config{
        aggregate: aggregate,
        event_codec: event_codec,
        snapshot: %Settings{version: version, sealed: sealed}
      }) do
    [aggregate, event_codec | Enum.sort(event_codec.__es_mods__())]
    |> Enum.map(& &1.module_info(:md5))
    |> then(&:erlang.md5([&1, Integer.to_string(version) | sealed_mark(sealed)]))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Шифротексты снапшотов `snapshots` потоков `states` к расшифровке вместе с хвостом событий:
  `{шифротекст, адрес}` в порядке потоков со снапшотом; у нешифрованных снапшотов — `[]`.
  """
  @spec sealed(Config.t(), map(), [struct()], [stored() | nil]) :: [{binary(), binary()}]

  def sealed(_cfg, %{sealed?: false}, _states, _snapshots), do: []

  def sealed(cfg, %{marker: marker}, states, snapshots)
      when is_binary(marker) and is_list(states) and is_list(snapshots) do
    for {%{id: id}, {version, binary}} <- Enum.zip(states, snapshots), do: {binary, aad(cfg, marker, id, version)}
  end

  @doc """
  Снапшот потока после расшифровки: исход `open` этого потока; `nil` — снапшота нет.
  """
  @spec opened(map(), stored() | nil, [KeyStore.opened()]) :: opened() | nil

  def opened(_plan, nil, _opened), do: nil

  def opened(%{sealed?: false}, {version, binary}, []), do: {version, {:ok, binary}}

  def opened(%{sealed?: true}, {version, _binary}, [outcome]), do: {version, outcome}

  @doc """
  Свернуть события хвоста `events` от снапшота `{version, opened}` потока состояния `initial`.

  Отказ снапшота — `:rejected` и `Logger.warning`: шифротекст не открылся (`:unreadable`), `binary`
  не читается `binary_to_term(bin, [:safe])`, ключи struct не совпали с `defstruct` агрегата, `id`
  или версия — с адресом снапшота, `fold/2` хвоста поднял исключение. Ключ субъекта уничтожен —
  `:destroyed` и `Logger.debug`: поток сворачивается целиком.
  """
  @spec fold(Config.t(), struct(), opened(), [Es.Event.t()]) :: {:ok, struct()} | :rejected | :destroyed

  def fold(cfg, %{id: id} = _initial, {version, opened}, events) when is_integer(version) and is_list(events) do
    case fold_snapshot(cfg.aggregate, id, {version, opened}, events) do
      {:ok, state} ->
        {:ok, state}

      {:error, :destroyed} ->
        Logger.debug(rejected_message(cfg, id, version, :destroyed))
        :destroyed

      {:error, reason} ->
        Logger.warning(rejected_message(cfg, id, version, reason))
        :rejected
    end
  end

  # ---

  defp sealed_mark(true), do: ["sealed"]
  defp sealed_mark(false), do: []

  defp fold_snapshot(_aggregate, _id, {_version, :destroyed}, _events), do: {:error, :destroyed}
  defp fold_snapshot(_aggregate, _id, {_version, :unreadable}, _events), do: {:error, :unreadable}

  defp fold_snapshot(aggregate, id, {version, {:ok, binary}}, events) when is_binary(binary) do
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

  defp rejected_message(cfg, id, version, reason) do
    "снапшот агрегата отвергнут: type=#{cfg.type} aggregate_id=#{cfg.codec.dump(id)} " <>
      "aggregate_version=#{version} reason=#{reason(reason)}"
  end

  defp reason({:fold, exception}), do: "fold error=#{inspect(exception)}"
  defp reason(reason), do: Atom.to_string(reason)

  # ===== запись =====

  @doc """
  Записать снапшоты состояний `states` одним upsert после commit
  (`Core.Helper.AfterCommit.register/1`), вне транзакции — сразу.

  Строка потока перезаписывается, только если её маркер другой или версия ниже. Отказ записи —
  `Logger.warning`, а не исключение: снапшот — кэш. `[]` — `:ok` без запроса.

  Шифрованные снапшоты — один `seal` на вызов, вне транзакции: ключ, которого нет, `seal` создаёт
  своим запросом. Отказ `:subject_destroyed` — снапшот этого субъекта не пишется
  (`Logger.debug`), остальные — повтором `seal` без него.
  """
  @spec write(Config.t(), map(), [struct()]) :: :ok

  def write(cfg, plan, states)

  def write(_cfg, _plan, []), do: :ok
  def write(cfg, plan, [_ | _] = states), do: AfterCommit.register(fn -> upsert(cfg, plan, states) end)

  # ---

  defp upsert(cfg, plan, states) do
    start = System.monotonic_time()
    {result, rows} = log_write(insert(cfg, plan, states), cfg, states)

    :telemetry.execute(
      Telemetry.event([:es, :snapshot, :write]),
      %{duration: System.monotonic_time() - start, rows: rows},
      %{type: cfg.type, result: result}
    )
  end

  defp insert(cfg, plan, states) do
    with {:ok, rows} <- rows(cfg, plan, states), do: {:ok, insert_all!(cfg, rows)}
  rescue
    exception -> {:error, exception}
  end

  defp rows(cfg, %{sealed?: false, marker: marker}, states),
    do: {:ok, Enum.map(states, &row(cfg, marker, &1, :erlang.term_to_binary(&1)))}

  defp rows(cfg, plan, states), do: sealed_rows(cfg, plan, states)

  defp sealed_rows(_cfg, _plan, []), do: {:ok, []}

  defp sealed_rows(cfg, %{marker: marker} = plan, states) do
    items =
      Enum.map(states, fn state ->
        {cfg.codec.dump(state.id), aad(cfg, marker, state.id, Version.value(state.version)),
         :erlang.term_to_binary(state)}
      end)

    case Port.seal(items) do
      {:ok, sealed} -> {:ok, Enum.zip_with(states, sealed, &row(cfg, marker, &1, &2))}
      {:error, error} -> without_destroyed(cfg, plan, states, error)
    end
  end

  # Отказ `seal` — на всю пачку: снапшоты остальных субъектов пишутся повтором без уничтоженного.
  defp without_destroyed(cfg, plan, states, %Error{ns: :key_store, code: :subject_destroyed} = error) do
    case Enum.split_with(states, &(cfg.codec.dump(&1.id) == error.detail.subject)) do
      {[], _states} ->
        {:error, error}

      {destroyed, states} ->
        Enum.each(destroyed, &log_destroyed(cfg, &1))
        sealed_rows(cfg, plan, states)
    end
  end

  defp without_destroyed(_cfg, _plan, _states, error), do: {:error, error}

  defp log_destroyed(cfg, state) do
    Logger.debug(
      "снапшот агрегата не записан: ключ субъекта уничтожен: type=#{cfg.type} " <>
        "aggregate_id=#{cfg.codec.dump(state.id)} aggregate_version=#{Version.value(state.version)}"
    )
  end

  defp insert_all!(_cfg, []), do: 0

  defp insert_all!(cfg, rows) do
    {rows, nil} =
      cfg.dao.insert_all(Schema, rows,
        on_conflict: on_conflict(),
        conflict_target: [:aggregate_type, :aggregate_id]
      )

    rows
  end

  defp row(cfg, marker, state, binary) do
    %{
      aggregate_type: cfg.type,
      aggregate_id: cfg.codec.dump(state.id),
      aggregate_version: Version.value(state.version),
      marker: marker,
      state: binary
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

  defp log_write({:error, reason}, cfg, states) do
    Logger.warning(
      "снапшоты агрегата не записаны: type=#{cfg.type} rows=#{length(states)} error=#{error_message(reason)}"
    )

    {:error, 0}
  end

  defp error_message(%Error{} = error), do: Error.format_chain(error)
  defp error_message(exception), do: Exception.message(exception)

  # ===== общее =====

  defp aad(cfg, marker, id, version),
    do: Port.address([cfg.type, cfg.codec.dump(id), Integer.to_string(version), marker])
end
