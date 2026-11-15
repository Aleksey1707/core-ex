defmodule Core.Es.Aggregate.Load.Engine do
  @moduledoc false

  alias Core.Error
  alias Core.Es
  alias Core.Es.Aggregate.Load.Plan
  alias Core.Es.Aggregate.Load.Request
  alias Core.Es.Aggregate.Load.Source
  alias Core.Es.Aggregate.Repo.Pg.Config
  alias Core.Es.Aggregate.Repo.Pg.Snapshot
  alias Core.Es.Aggregate.Repo.Pg.Snapshot.Settings
  alias Core.Es.Personal.Destroyed
  alias Core.Result
  alias Core.Telemetry
  alias Core.Version

  @typedoc false
  @type entry :: Source.entry()

  @typedoc false
  @type meta :: %{
          state: struct(),
          captures: [pos_integer()],
          version: Version.expected() | nil,
          aggregate_id: binary()
        }

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
  @type loaded :: %{
          restored: [restored()],
          result: Result.t([struct()] | struct())
        }

  @doc false
  @spec read(Config.t(), Plan.t(), Request.t()) :: Result.t(loaded())

  def read(cfg, plan, request) do
    with {:ok, restored} <- restore(cfg, plan, request) do
      {:ok, %{restored: restored, result: verify(cfg, request, restored)}}
    end
  end

  @doc false
  @spec mismatch(Config.t(), struct(), pos_integer() | nil, :expected | :address) :: Error.t()

  def mismatch(cfg, state, expected, source), do: version_mismatch(cfg, detail(cfg, state, expected, source))

  # ---

  defp restore(_cfg, _plan, %{streams: []}), do: {:ok, []}

  defp restore(cfg, plan, %{streams: specs} = request) do
    metas = Enum.map(specs, &meta(cfg, &1))
    triples = request.source.fetch(cfg, plan, request.opts)

    with {:ok, restored} <- open_tails(cfg, plan, pair(metas, triples)),
         {:ok, restored} <- refold_rejected(cfg, plan, restored, request.source, request.opts) do
      Enum.each(restored, &emit_fold(cfg, request.op, &1))
      {:ok, restored}
    end
  end

  # Сверка идёт по мете потока: ожидаемая версия — `request.streams`/адрес, фактическая — голова.
  defp verify(cfg, %{op: :get_at, version: version}, [restored]), do: verify_at(cfg, restored, version)

  defp verify(cfg, %{op: :get_many_at, pairs: pairs}, restored), do: verify_many_at(cfg, restored, pairs)

  defp verify(cfg, request, restored), do: verify_head(cfg, request, restored)

  defp verify_head(cfg, request, restored) do
    born? = request.born?
    results = Enum.map(restored, &head_result(cfg, &1, born?))

    case for {:error, detail} <- results, do: detail do
      [] -> {:ok, for({:ok, state} <- results, do: state)}
      details -> {:error, version_mismatch(cfg, head_details(request, details))}
    end
  end

  defp head_details(%{op: :get_many}, details), do: details
  defp head_details(_request, [detail]), do: detail
  defp head_details(_request, details), do: details

  defp head_result(_cfg, %{state: state, meta: %{version: :current}}, _born?), do: {:ok, state}

  defp head_result(cfg, %{state: state, meta: %{version: %Version{} = expected}}, born?) do
    cond do
      match?(%Version{}, state.version) and state.version == expected -> {:ok, state}
      is_nil(state.version) and born? -> {:ok, state}
      true -> {:error, detail(cfg, state, Version.value(expected), :expected)}
    end
  end

  defp verify_at(_cfg, %{state: %{version: version} = state}, %Version{} = version), do: {:ok, state}

  defp verify_at(cfg, %{state: state}, %Version{} = version),
    do: {:error, version_mismatch(cfg, detail(cfg, state, Version.value(version), :address))}

  # Состояние каждой пары — снятие на её версии; нет — адрес за головой потока или пустой поток.
  defp verify_many_at(cfg, restored, pairs) do
    by_id = Map.new(restored, &{&1.state.id, &1})
    id_mod = cfg.id

    results =
      Enum.map(pairs, fn {%^id_mod{} = id, expected} ->
        stream = Map.fetch!(by_id, id)

        case Map.fetch(stream.captures, expected) do
          {:ok, state} -> {:ok, state}
          :error -> {:error, detail(cfg, stream.state, expected, :address)}
        end
      end)

    case for {:error, detail} <- results, do: detail do
      [] -> {:ok, for({:ok, state} <- results, do: state)}
      details -> {:error, version_mismatch(cfg, details)}
    end
  end

  defp detail(cfg, state, expected, source) do
    %{
      aggregate_id: cfg.codec.dump(state.id),
      expected: expected,
      actual: state.version && Version.value(state.version),
      source: source
    }
  end

  defp version_mismatch(cfg, detail), do: cfg.errors.domain(cfg.behaviour, :version_mismatch, detail)

  defp meta(cfg, spec) do
    %{
      state: spec.state,
      captures: spec.captures,
      version: spec.version,
      aggregate_id: cfg.codec.dump(spec.state.id)
    }
  end

  # Потоки источника сходятся по адресу: порядок выдачи снапшот с потоком не путает.
  defp pair(metas, triples) do
    by_address = Map.new(triples, fn {stream, snapshot, rows} -> {stream.aggregate_id, {snapshot, rows}} end)

    for meta <- metas do
      {snapshot, rows} = Map.fetch!(by_address, meta.aggregate_id)
      {meta, snapshot, rows}
    end
  end

  # Хвост потока расшифровывается вместе с его снапшотом: исходы не общие и не позиционные.
  defp open_tails(cfg, plan, triples) do
    triples
    |> Enum.reduce_while({:ok, []}, fn {meta, snapshot, rows}, {:ok, acc} ->
      case open_tail(cfg, plan, meta, snapshot, rows) do
        {:ok, stream} -> {:cont, {:ok, [stream | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, restored} -> {:ok, Enum.reverse(restored)}
      error -> error
    end
  end

  defp open_tail(%Config{snapshot: nil} = cfg, _plan, meta, _snapshot, rows) do
    with {:ok, {events, []}} <- Es.Store.load_fold_rows(rows, cfg.event_codec, cfg.codec, []),
         do: {:ok, fold_stream(cfg, meta, nil, events)}
  end

  defp open_tail(%Config{} = cfg, plan, meta, snapshot, rows) do
    sealed = Snapshot.sealed(cfg, plan, [meta.state], [snapshot])

    with {:ok, {events, opened}} <- Es.Store.load_fold_rows(rows, cfg.event_codec, cfg.codec, sealed),
         do: {:ok, fold_stream(cfg, meta, Snapshot.opened(plan, snapshot, opened), events)}
  end

  defp fold_stream(%Config{snapshot: nil} = cfg, meta, _snapshot, events),
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
  defp refold_rejected(cfg, plan, restored, source, opts) do
    rejected = for %{rejected?: true} = stream <- restored, do: stream

    case rejected do
      [] -> {:ok, restored}
      [_ | _] -> refold(cfg, plan, restored, rejected, source, opts)
    end
  end

  defp refold(cfg, plan, restored, rejected, source, opts) do
    plan = Plan.refold(plan, Enum.map(rejected, & &1.meta.aggregate_id))
    metas = Enum.map(rejected, & &1.meta)
    triples = source.fetch(cfg, plan, opts)

    with {:ok, refolded} <- open_tails(cfg, plan, pair(metas, triples)),
         do: {:ok, replace_rejected(restored, refolded)}
  end

  defp replace_rejected(restored, refolded) do
    by_address = Map.new(refolded, &{&1.meta.aggregate_id, &1})

    Enum.map(restored, fn
      %{rejected?: true} = placeholder ->
        merge_refolded(placeholder, Map.fetch!(by_address, placeholder.meta.aggregate_id))

      stream ->
        stream
    end)
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
  defp destroyed?(%Config{snapshot: %Settings{sealed: true}}, events), do: destroyed_value?(events)
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

  defp emit_fold(cfg, op, %{snapshot: snapshot, events: events}) do
    :telemetry.execute(
      Telemetry.event([:es, :aggregate, :fold]),
      %{events: events},
      %{type: cfg.type, op: op, snapshot: snapshot}
    )
  end
end
