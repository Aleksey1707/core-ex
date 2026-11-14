defmodule Core.Es.Aggregate.Load do
  @moduledoc false

  alias Core.Error
  alias Core.Es
  alias Core.Es.Aggregate.Repo.Pg.Snapshot
  alias Core.Es.Personal.Destroyed
  alias Core.Es.Store.Schema
  alias Core.Result
  alias Core.Telemetry
  alias Core.Version

  @typedoc false
  @type meta :: %{
          state: struct(),
          captures: [pos_integer()],
          version: Version.expected() | nil,
          aggregate_id: binary(),
          after_version: non_neg_integer(),
          to_version: pos_integer() | nil,
          snapshot_to: pos_integer() | nil,
          snapshot?: boolean()
        }

  @typedoc false
  @type triple :: {meta(), Snapshot.stored() | nil, [Schema.t()]}

  @typedoc false
  @type source :: (map(), [meta()], keyword() -> [triple()])

  @typedoc false
  @type restored :: %{
          meta: meta(),
          snapshot: :hit | :miss | :rejected | :off,
          state: struct(),
          events: non_neg_integer(),
          destroyed?: boolean(),
          captures: %{pos_integer() => struct()},
          rejected?: boolean()
        }

  @typedoc false
  @type request :: %{
          required(:op) => atom(),
          required(:opts) => keyword(),
          required(:source) => source(),
          required(:write?) => boolean(),
          required(:verify) => ([restored()] -> Result.t()),
          optional(:states) => [%{state: struct(), version: Version.expected()}],
          optional(:state) => struct()
        }

  @typep spec :: %{
           state: struct(),
           version: Version.expected() | nil,
           upper: pos_integer() | nil,
           captures: [pos_integer()]
         }

  @typep address :: %{
           required(:kind) => :head | :at | :many_at,
           required(:streams) => [spec()],
           optional(:version) => Version.t(),
           optional(:pairs) => [{struct(), pos_integer()}]
         }

  # ===== чтение =====

  @doc false
  @spec head(map(), request()) :: Result.t([struct()])

  def head(cfg, %{states: states} = request) do
    streams = Enum.map(states, &%{state: &1.state, version: &1.version, upper: nil, captures: []})

    run(cfg, request, %{kind: :head, streams: streams})
  end

  # ===== версия =====

  @doc false
  @spec at(map(), request(), Version.t()) :: Result.t(struct())

  def at(cfg, %{state: state} = request, %Version{} = version) do
    streams = [%{state: state, version: version, upper: Version.value(version), captures: []}]

    run(cfg, request, %{kind: :at, streams: streams, version: version})
  end

  @doc false
  @spec many_at(map(), request(), [{struct(), Version.t()}]) :: Result.t([struct()])

  def many_at(cfg, request, pairs) do
    id_mod = cfg.id

    parsed =
      Enum.map(pairs, fn
        {%^id_mod{} = id, %Version{} = version} -> {id, Version.value(version)}
      end)

    ids =
      parsed
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()

    streams =
      Enum.map(ids, fn id ->
        captures =
          parsed
          |> Enum.flat_map(fn
            {^id, version} -> [version]
            {_other, _version} -> []
          end)
          |> Enum.uniq()
          |> Enum.sort()

        %{state: struct(cfg.aggregate, id: id), version: nil, upper: nil, captures: captures}
      end)

    run(cfg, request, %{kind: :many_at, streams: streams, pairs: parsed})
  end

  # ===== общее =====

  @spec run(map(), request(), address()) :: Result.t()

  defp run(cfg, %{op: op} = request, %{streams: streams}) do
    start = System.monotonic_time()

    with {:ok, restored} <- restore(cfg, request, streams) do
      result = request.verify.(restored)

      :telemetry.execute(
        Telemetry.event([:es, :aggregate, :load]),
        measurements(restored, System.monotonic_time() - start),
        %{type: cfg.type, op: op, result: result_tag(result)}
      )

      write_snapshots(cfg, restored, request.write?)
      result
    end
  end

  defp restore(_cfg, _request, []), do: {:ok, []}

  defp restore(cfg, request, streams) do
    metas = Enum.map(streams, &stream(cfg, &1))
    triples = request.source.(cfg, metas, request.opts)

    with {:ok, restored} <- open_tails(cfg, triples),
         {:ok, restored} <- refold_rejected(cfg, restored, request.source, request.opts) do
      Enum.each(restored, &emit_fold(cfg, request.op, &1))
      {:ok, restored}
    end
  end

  defp stream(cfg, spec) do
    %{
      state: spec.state,
      captures: spec.captures,
      version: spec.version,
      aggregate_id: cfg.codec.dump(spec.state.id),
      after_version: after_version(spec.state),
      to_version: to_version(spec),
      snapshot_to: snapshot_to(spec),
      snapshot?: cfg.snapshot != nil
    }
  end

  # Потолок потока — верхняя версия или наибольшая версия пакета; снапшот — не выше наименьшей.
  defp to_version(%{captures: [_ | _] = captures}), do: Enum.max(captures)
  defp to_version(%{upper: upper}), do: upper

  defp snapshot_to(%{captures: [_ | _] = captures}), do: Enum.min(captures)
  defp snapshot_to(%{upper: upper}), do: upper

  defp after_version(%{version: nil}), do: 0
  defp after_version(%{version: %Version{} = version}), do: Version.value(version)

  # Все строки всех потоков открываются одним вызовом; шифротексты снапшотов — тоже.
  defp open_tails(%{snapshot: nil} = cfg, triples) do
    with {:ok, {events, []}} <- load_rows(cfg, triples, []), do: distribute(cfg, triples, events, [])
  end

  defp open_tails(cfg, triples) do
    snapshots = Enum.map(triples, &elem(&1, 1))
    states = Enum.map(triples, fn {meta, _snapshot, _rows} -> meta.state end)
    sealed = Snapshot.sealed(cfg, Snapshot.marker(cfg), states, snapshots)

    with {:ok, {events, opened}} <- load_rows(cfg, triples, sealed),
         do: distribute(cfg, triples, events, opened)
  end

  defp load_rows(cfg, triples, sealed) do
    rows = Enum.flat_map(triples, fn {_meta, _snapshot, rows} -> rows end)

    Es.Store.load_fold_rows(rows, cfg.event_codec, cfg.codec, sealed)
  end

  # События и исходы снапшотов — общие списки на весь вызов; каждый трипл берёт свой отрезок.
  defp distribute(cfg, triples, events, opened) do
    {restored, {[], []}} =
      Enum.map_reduce(triples, {events, opened}, fn triple, acc -> fold_triple(cfg, triple, acc) end)

    {:ok, restored}
  end

  defp fold_triple(cfg, {meta, snapshot, rows}, {events, opened}) do
    {stream_events, rest_events} = Enum.split(events, length(rows))
    {opened_snapshot, opened} = open_snapshot(cfg, snapshot, opened)

    {fold_stream(cfg, meta, opened_snapshot, stream_events), {rest_events, opened}}
  end

  defp open_snapshot(_cfg, nil, opened), do: {nil, opened}

  defp open_snapshot(cfg, snapshot, opened) do
    {outcomes, opened} = take_outcomes(cfg, opened)
    [opened_snapshot] = Snapshot.put_opened(cfg, [snapshot], outcomes)

    {opened_snapshot, opened}
  end

  defp take_outcomes(%{snapshot: %{sealed: false}}, opened), do: {[], opened}
  defp take_outcomes(%{snapshot: %{sealed: true}}, [outcome | opened]), do: {[outcome], opened}

  defp fold_stream(%{snapshot: nil} = cfg, meta, _snapshot, events),
    do: restored_stream(:off, cfg, meta, meta.state, events, false)

  defp fold_stream(cfg, meta, nil, events),
    do: restored_stream(:miss, cfg, meta, meta.state, events, destroyed?(cfg, events))

  # Без версий пакета снапшот сворачивается вместе с хвостом одним `Snapshot.fold`. С версиями
  # пакета — только базовое состояние снапшота, а хвост один раз режется по границам версий.
  defp fold_stream(cfg, %{captures: []} = meta, snapshot, events) do
    case Snapshot.fold(cfg, meta.state, snapshot, events) do
      {:ok, state} -> restored_state(:hit, meta, state, events, destroyed?(cfg, events), %{})
      :rejected -> rejected_stream(meta, false)
      :destroyed -> rejected_stream(meta, true)
    end
  end

  defp fold_stream(cfg, meta, snapshot, events) do
    case Snapshot.fold(cfg, meta.state, snapshot, []) do
      {:ok, base} -> restored_stream(:hit, cfg, meta, base, events, destroyed?(cfg, events))
      :rejected -> rejected_stream(meta, false)
      :destroyed -> rejected_stream(meta, true)
    end
  end

  defp rejected_stream(meta, destroyed?) do
    %{
      meta: meta,
      snapshot: :rejected,
      state: meta.state,
      events: 0,
      destroyed?: destroyed?,
      captures: %{},
      rejected?: true
    }
  end

  # Повторное чтение отвергнутых снапшотов — вторым запросом, без снапшотов; замена — по флагу.
  defp refold_rejected(cfg, restored, source, opts) do
    rejected = for %{rejected?: true} = stream <- restored, do: stream

    case rejected do
      [] -> {:ok, restored}
      [_ | _] -> refold(cfg, restored, rejected, source, opts)
    end
  end

  defp refold(cfg, restored, rejected, source, opts) do
    metas = Enum.map(rejected, &%{&1.meta | snapshot?: false})
    triples = source.(cfg, metas, opts)

    with {:ok, refolded} <- open_tails(cfg, triples), do: {:ok, replace_rejected(restored, refolded)}
  end

  defp replace_rejected(restored, refolded) do
    {merged, []} =
      Enum.map_reduce(restored, refolded, fn
        %{rejected?: true} = stream, [refolded | rest] -> {merge_refolded(stream, refolded), rest}
        stream, refolded -> {stream, refolded}
      end)

    merged
  end

  defp merge_refolded(placeholder, refolded) do
    %{
      refolded
      | snapshot: :rejected,
        rejected?: false,
        destroyed?: placeholder.destroyed? or refolded.destroyed?
    }
  end

  # `destroyed?` — чтение видело уничтоженный снапшот или ПДн-значение: снапшот потока не пишется.
  defp destroyed?(%{snapshot: %{sealed: true}}, events), do: destroyed_value?(events)
  defp destroyed?(_cfg, _events), do: false

  # Поле с `subject:` — только на верхнем уровне нагрузки.
  defp destroyed_value?(events) do
    Enum.any?(events, fn
      %{payload: %_{} = payload} -> Enum.any?(Map.from_struct(payload), &match?({_field, %Destroyed{}}, &1))
      _event -> false
    end)
  end

  # `captures` — состояния на версиях пакета (`%{version => state}`), у обычного чтения пусто.
  defp restored_stream(snapshot, cfg, meta, base, events, destroyed?) do
    {state, captures} = fold_captures(cfg, meta.captures, base, events)

    restored_state(snapshot, meta, state, events, destroyed?, captures)
  end

  defp restored_state(snapshot, meta, state, events, destroyed?, captures) do
    %{
      meta: meta,
      snapshot: snapshot,
      state: state,
      events: length(events),
      destroyed?: destroyed?,
      captures: captures,
      rejected?: false
    }
  end

  # Режем события по границам версий пакета: каждый отрезок — продолжение свёртки предыдущего,
  # поэтому свёрнутых событий столько же. Версия выше головы не снимается.
  defp fold_captures(cfg, [], state, events), do: {cfg.aggregate.fold(state, events), %{}}

  defp fold_captures(cfg, captures, base, events) do
    {captures, state, rest} =
      captures
      |> Enum.sort()
      |> Enum.uniq()
      |> Enum.reduce({%{}, base, events}, fn capture, {captures, state, events} ->
        {upto, rest} = Enum.split_while(events, &(Version.value(&1.aggregate_version) <= capture))
        state = cfg.aggregate.fold(state, upto)

        captures =
          if state.version && Version.value(state.version) == capture,
            do: Map.put(captures, capture, state),
            else: captures

        {captures, state, rest}
      end)

    {cfg.aggregate.fold(state, rest), captures}
  end

  defp measurements(restored, duration) do
    counts = Enum.frequencies_by(restored, & &1.snapshot)

    %{
      duration: duration,
      streams: length(restored),
      events: Enum.sum_by(restored, & &1.events),
      snapshot_hit: Map.get(counts, :hit, 0),
      snapshot_miss: Map.get(counts, :miss, 0),
      snapshot_rejected: Map.get(counts, :rejected, 0)
    }
  end

  defp emit_fold(cfg, op, %{snapshot: snapshot, events: events}) do
    :telemetry.execute(
      Telemetry.event([:es, :aggregate, :fold]),
      %{events: events},
      %{type: cfg.type, op: op, snapshot: snapshot}
    )
  end

  defp write_snapshots(_cfg, _restored, false), do: :ok

  defp write_snapshots(%{snapshot: nil}, _restored, _write?), do: :ok

  defp write_snapshots(%{snapshot: %{every: every}} = cfg, restored, true) do
    states = for %{state: state, events: events, destroyed?: false} <- restored, events >= every, do: state
    Snapshot.write(cfg, states)
  end

  defp result_tag({:ok, _}), do: :ok
  defp result_tag({:error, %Error{code: :version_mismatch}}), do: :version_mismatch
end
