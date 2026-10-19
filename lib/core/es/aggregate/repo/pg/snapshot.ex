defmodule Core.Es.Aggregate.Repo.Pg.Snapshot do
  @moduledoc """
  Снапшоты write-репозитория event-sourced агрегата (`use Core.Es.Aggregate.Repo.Pg, snapshot:`):
  опция — на компиляции; маркер, свёртка от снапшота и его запись — в рантайме.

  Снапшот — кэш свёртки, а не wire: состояние хранится `:erlang.term_to_binary/1` в
  `es_snapshots` (`Core.Es.Migration`) и читается `binary_to_term(bin, [:safe])` без кодека и без
  `new/1` Prim. Устаревшую форму состояния отсекает маркер, битую — сверка ключей struct с
  `defstruct`, `id` и версии — с адресом строки.

  У агрегата с ПДн в событиях (`__es_subjects__/0` кодека не пуст) снапшот — одно ПДн-значение
  субъекта `aggregate_id` (ADR-0076): `term_to_binary` состояния целиком шифрует `seal` хранилища
  ключей (`Core.Es.Personal.Port`), AAD — `Core.Es.Personal.Port.address/1` над типом агрегата,
  `aggregate_id`, версией и маркером. Признак шифрованного снапшота входит в маркер.
  """

  import Ecto.Query, only: [from: 2]

  alias Core.Error
  alias Core.Es
  alias Core.Es.Aggregate.Repo.Pg.Snapshot.Schema
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

  @typedoc "Настройка снапшотов репозитория; `sealed` — снапшот шифруется под ключом субъекта."
  @type t :: %{every: pos_integer(), version: integer(), sealed: boolean()}

  @typedoc "Снапшот потока: версия и binary состояния."
  @type stored :: {pos_integer(), binary()}

  @typedoc "Снапшот потока после расшифровки: версия и исход `open` (у нешифрованного — `{:ok, binary}`)."
  @type opened :: {pos_integer(), KeyStore.opened()}

  # ===== опции =====

  @doc """
  Опция `snapshot:` → настройка снапшотов; `subjects` — `__es_subjects__/0` кодека событий.

  Неверная опция и субъект ПДн-поля не `:aggregate_id` — `CompileError`.
  """
  @spec opts!(term(), %{optional(module()) => [{atom(), atom()}]}, String.t()) :: t()

  def opts!(opts, subjects, label) when is_map(subjects) and is_binary(label) do
    label = "#{label}: snapshot"
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, label)

    %{
      every: every!(Keyword.fetch!(opts, :every), label),
      version: version!(Keyword.get(opts, :version, @default_version), label),
      sealed: sealed!(subjects, label)
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

  # Снапшот — одно ПДн-значение одного субъекта: ПДн другого субъекта под ключом агрегата не
  # уничтожались бы вместе со своим ключом.
  defp sealed!(subjects, label) do
    fields = for {mod, fields} <- subjects, {field, subject} <- fields, subject != :aggregate_id, do: {mod, field}

    case Enum.sort(fields) do
      [] ->
        subjects != %{}

      fields ->
        raise CompileError,
          description:
            "#{label}: субъект ПДн-поля — поле нагрузки, а не :aggregate_id: " <>
              Enum.map_join(fields, ", ", fn {mod, field} -> "#{inspect(mod)}.#{field}" end)
    end
  end

  # ===== восстановление =====

  @doc """
  Маркер снапшотов репозитория: md5 загруженных модулей агрегата, кодека событий и событий
  кодека плюс `version:` и признак шифрованного снапшота.

  Считается по коду, который исполняется сейчас, а не на компиляции репозитория: правка любого из
  этих модулей меняет маркер без пересборки репозитория.
  """
  @spec marker(map()) :: String.t()

  def marker(%{aggregate: aggregate, event_codec: event_codec, snapshot: %{version: version, sealed: sealed}}) do
    [aggregate, event_codec | Enum.sort(event_codec.__es_mods__())]
    |> Enum.map(& &1.module_info(:md5))
    |> then(&:erlang.md5([&1, Integer.to_string(version) | sealed_mark(sealed)]))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Шифротексты снапшотов `snapshots` потоков `states` к расшифровке вместе с хвостом событий:
  `{шифротекст, адрес}` в порядке потоков со снапшотом; у нешифрованных снапшотов — `[]`.
  """
  @spec sealed(map(), String.t(), [struct()], [stored() | nil]) :: [{binary(), binary()}]

  def sealed(%{snapshot: %{sealed: false}}, _marker, _states, _snapshots), do: []

  def sealed(cfg, marker, states, snapshots) when is_binary(marker) and is_list(states) and is_list(snapshots) do
    for {%{id: id}, {version, binary}} <- Enum.zip(states, snapshots), do: {binary, aad(cfg, marker, id, version)}
  end

  @doc """
  Снапшоты после расшифровки: исходы `opened` по порядку встают на место шифротекстов; у
  нешифрованных снапшотов `opened` — `[]`, а binary становится `{:ok, binary}`.
  """
  @spec put_opened(map(), [stored() | nil], [KeyStore.opened()]) :: [opened() | nil]

  def put_opened(%{snapshot: %{sealed: false}}, snapshots, []) when is_list(snapshots) do
    Enum.map(snapshots, fn
      nil -> nil
      {version, binary} -> {version, {:ok, binary}}
    end)
  end

  def put_opened(%{snapshot: %{sealed: true}}, snapshots, opened) when is_list(snapshots) and is_list(opened) do
    {snapshots, []} =
      Enum.map_reduce(snapshots, opened, fn
        nil, opened -> {nil, opened}
        {version, _binary}, [outcome | opened] -> {{version, outcome}, opened}
      end)

    snapshots
  end

  @doc """
  Свернуть события хвоста `events` от снапшота `{version, opened}` потока состояния `initial`.

  Отказ снапшота — `:rejected` и `Logger.warning`: шифротекст не открылся (`:unreadable`), `binary`
  не читается `binary_to_term(bin, [:safe])`, ключи struct не совпали с `defstruct` агрегата, `id`
  или версия — с адресом снапшота, `fold/2` хвоста поднял исключение. Ключ субъекта уничтожен —
  `:destroyed` и `Logger.debug`: поток сворачивается целиком.
  """
  @spec fold(map(), struct(), opened(), [Es.Event.t()]) :: {:ok, struct()} | :rejected | :destroyed

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
    marker = marker(cfg)

    with {:ok, rows} <- rows(cfg, marker, states), do: {:ok, insert_all!(cfg, rows)}
  rescue
    exception -> {:error, exception}
  end

  defp rows(%{snapshot: %{sealed: false}} = cfg, marker, states),
    do: {:ok, Enum.map(states, &row(cfg, marker, &1, :erlang.term_to_binary(&1)))}

  defp rows(cfg, marker, states), do: sealed_rows(cfg, marker, states)

  defp sealed_rows(_cfg, _marker, []), do: {:ok, []}

  defp sealed_rows(cfg, marker, states) do
    items =
      Enum.map(states, fn state ->
        {cfg.codec.dump(state.id), aad(cfg, marker, state.id, Version.value(state.version)),
         :erlang.term_to_binary(state)}
      end)

    case Port.seal(items) do
      {:ok, sealed} -> {:ok, Enum.zip_with(states, sealed, &row(cfg, marker, &1, &2))}
      {:error, error} -> without_destroyed(cfg, marker, states, error)
    end
  end

  # Отказ `seal` — на всю пачку: снапшоты остальных субъектов пишутся повтором без уничтоженного.
  defp without_destroyed(cfg, marker, states, %Error{ns: :key_store, code: :subject_destroyed} = error) do
    case Enum.split_with(states, &(cfg.codec.dump(&1.id) == error.detail.subject)) do
      {[], _states} ->
        {:error, error}

      {destroyed, states} ->
        Enum.each(destroyed, &log_destroyed(cfg, &1))
        sealed_rows(cfg, marker, states)
    end
  end

  defp without_destroyed(_cfg, _marker, _states, error), do: {:error, error}

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
