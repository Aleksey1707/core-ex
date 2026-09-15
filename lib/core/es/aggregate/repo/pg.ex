defmodule Core.Es.Aggregate.Repo.Pg do
  @moduledoc """
  Билдер write-репозитория event-sourced агрегата на хранилище событий (`Core.Es.Store`).

      defmodule MyApp.Domain.<BC>.Common.Account.Repo.Pg do
        alias MyApp.Domain.<BC>.Common.Account

        use Core.Es.Aggregate.Repo.Pg,
          behaviour: MyApp.Domain.<BC>.Common.Account.Repo,
          aggregate: Account,
          id: Account.ID,
          errors: Account.Errors,
          outbox: Account.Outbox
      end

  Строки состояния нет: `get` / `get_many` / `refresh` сворачивают события потока через
  `Agg.fold/2`; тип агрегата и семейство событий — из кодека `__es_event_codec__/0` агрегата.
  `Repo.Sc`, `default_filters` и `delete` не участвуют: доступ решают usecase и `decide`,
  удаление — доменное событие.

  ## Генерируемые функции

  - `get(id, version, context, opts)` — пустой поток — `%Agg{id: id, version: nil}`, а не
    `:not_found`: существование агрегата решает `decide`. `%Version{}`, не равная голове потока
    после свёртки, — `:version_mismatch`, у пустого потока `actual: nil`.
  - `get_many(pairs, context, opts)` — все потоки одним запросом, состояния в порядке пар `{id,
    version}`; все расхождения — одна `:version_mismatch` со списком detail в порядке пар; `[]` —
    `{:ok, []}` без запросов; повтор id — `ArgumentError`.
  - `append(events, context, opts)` — `[]` — `:ok` без запросов; иначе в
    `Core.Helper.Transact.run/3`: `outbox.from_events` → `Core.Es.Store.append/5` с
    непрерывностью потока → `Core.Config.outbox_repo().append`. События нескольких потоков одного
    типа пишутся пачкой, отказ в любом потоке откатывает всю; событие не из `tags:` кодека —
    `FunctionClauseError`.
  - `refresh(state, version, context, opts)` — события потока после `state.version`, свёрнутые
    от `state`; `version` сверяется, как у `get`.

  `opts` — опции запроса и транзакции. Функции `defoverridable`.

  `:version_mismatch` — `errors.domain(behaviour, :version_mismatch, detail)`, detail —
  `%{aggregate_id, expected, actual}` (`t:Core.Es.Store.mismatch_detail/0`): у `append` его
  строит хранилище, у чтения `expected` — значение `version`, `actual` — версия после свёртки.

  Нечитаемый поток — исключение: неизвестный тег — `Core.Exc` загрузки фасадом, разрыв версий —
  `ArgumentError` из `Agg.fold/2`.

  ## Снапшоты

  `snapshot: [every: N, version: V]` — кэш свёртки в `es_snapshots` (`Core.Es.Migration`), по
  умолчанию выключен. Удаление снапшота корректность не меняет: версию проверяет `append`.

  - Чтение — тем же одним запросом: снапшот потока с текущим маркером и версией выше версии
    состояния и события после него. Маркер — md5 загруженных модулей агрегата, кодека событий и
    событий плюс `version:`; снапшот другого маркера — промах, а не отказ.
  - Отказ снапшота — `Logger.warning` и весь поток вторым запросом: состояние не читается
    `binary_to_term(bin, [:safe])`, ключи struct, `id` или версия не совпали, `fold/2` хвоста от
    снапшота поднял исключение. Исключение наружу — только если не читается сам поток.
  - Запись — у потоков, где вызов свернул не меньше `every` событий (после снапшота или от
    состояния): один upsert на вызов после commit (`Core.Helper.AfterCommit`), вне транзакции —
    сразу. Строка перезаписывается, если маркер другой или версия выше; отказ записи —
    `Logger.warning`, успех — `Logger.debug`. `append` снапшоты не пишет.
  - Правку кода, от которого `evolve` зависит вне этих модулей, маркер не видит — поднять
    `version:`.

  ## Telemetry

  Имена — `Core.Telemetry.event/1`; span'а у восстановления нет, на нечитаемом потоке события
  не шлются.

  - `[:es, :aggregate, :load]` — на вызов `get` / `get_many` / `refresh`:
    измерения `duration` (native, без записи снапшотов), `streams`, `events` (свёрнутые),
    `snapshot_hit`, `snapshot_miss`, `snapshot_rejected` (потоки; без `snapshot:` — нули);
    метаданные `type` (тип агрегата), `op` (`:get`, `:get_many`, `:refresh`), `result` (`:ok`,
    `:version_mismatch`).
  - `[:es, :aggregate, :fold]` — на свёрнутый поток: измерение `events`; метаданные `type`,
    `snapshot` (`:hit`, `:miss`, `:rejected`, без `snapshot:` — `:off`).
  - `[:es, :snapshot, :write]` — на upsert снапшотов: измерения `duration` (native), `rows`
    (записанные строки, при отказе — 0); метаданные `type`, `result` (`:ok`, `:error`).

  ## Opts

  - `behaviour:` — `use Core.Es.Aggregate.Repo`; модуль ошибок `:version_mismatch`
  - `aggregate:` — `use Core.Es.Aggregate`
  - `id:` — Prim идентификатора агрегата
  - `errors:` — каталог ошибок с clause `:version_mismatch`
  - `outbox:` — `<Aggregate>.Outbox` (`use Core.Es.Outbox`)
  - `repo:` — Ecto-репозиторий транзакции `append` и чтения потока; по умолчанию
    `Core.Config.dao/0` в рантайме. Сами события `Core.Es.Store.append/5` пишет через
    `Core.Config.dao/0`
  - `codec:` — фасад дампа id и загрузки событий на чтении; по умолчанию `Core.Config.codec/0`
    в рантайме
  - `snapshot:` — `[every: N, version: V]`, без опции снапшоты выключены: `every:` — сколько
    свёрнутых событий потока дают запись снапшота, целое больше нуля, обязательна; `version:` —
    ручная часть маркера, целое, по умолчанию 1

  На компиляции `CompileError`, если `behaviour:` не объявляет колбэки
  `Core.Es.Aggregate.Repo`, `aggregate:` — не event-sourced агрегат, и на сверках
  `Core.Es.Store.Opts`: кодек агрегата без `type:`, его Prim агрегата не равен `id:`, событие
  `outbox:` не равно семейству кодека, в `errors:` нет clause `:version_mismatch`; `snapshot:` —
  не keyword, без `every:`, с неизвестной опцией, `every:` не целое больше нуля или `version:` не
  целое.

  Макрос занимает в вызывающем модуле имя `@es_aggregate_repo` и приватную `es_aggregate_repo/0`.
  """

  import Core.Version, only: [is_version: 1]
  import Ecto.Query

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Es.Aggregate.Repo.Pg.Snapshot
  alias Core.Es.Store.Schema
  alias Core.Helper
  alias Core.Helper.Transact
  alias Core.Telemetry
  alias Core.Version

  @label "Es.Aggregate.Repo.Pg"
  @required_keys ~w(behaviour aggregate id errors outbox)a
  @optional_keys ~w(repo codec snapshot)a
  @stream_types %{index: :integer, aggregate_id: :binary_id, after_version: :integer}

  @doc "Реализовать write-репозиторий event-sourced агрегата на хранилище событий."
  defmacro __using__(opts) do
    lit = Macro.expand_literals(opts, __CALLER__)
    cfg = validate_opts!(lit)
    dao = Helper.Opts.module_or_config!(lit, :repo, :dao, @label)
    codec = Helper.Opts.module_or_config!(lit, :codec, :codec, @label)

    quote do
      @behaviour unquote(cfg.behaviour)

      @es_aggregate_repo unquote(Macro.escape(cfg))

      import Core.Version, only: [is_version: 1]

      @doc "Состояние агрегата из его потока; `version` сверяется с головой потока."
      @impl true
      def get(%unquote(cfg.id){} = id, version, %Core.Context{} = context, opts \\ [])
          when is_version(version) and is_list(opts),
          do: Core.Es.Aggregate.Repo.Pg.get(es_aggregate_repo(), id, version, context, opts)

      @doc "Состояния агрегатов по парам `{id, version}` одним запросом, в порядке пар."
      @impl true
      def get_many(pairs, %Core.Context{} = context, opts \\ [])
          when is_list(pairs) and is_list(opts),
          do: Core.Es.Aggregate.Repo.Pg.get_many(es_aggregate_repo(), pairs, context, opts)

      @doc "Записать события агрегатов в хранилище событий и outbox одной транзакцией."
      @impl true
      def append(events, %Core.Context{} = context, opts \\ [])
          when is_list(events) and is_list(opts),
          do: Core.Es.Aggregate.Repo.Pg.append(es_aggregate_repo(), events, context, opts)

      @doc "Дочитать поток после `state.version`; `version` сверяется с головой потока."
      @impl true
      def refresh(
            %unquote(cfg.aggregate){} = state,
            version,
            %Core.Context{} = context,
            opts \\ []
          )
          when is_version(version) and is_list(opts),
          do:
            Core.Es.Aggregate.Repo.Pg.refresh(es_aggregate_repo(), state, version, context, opts)

      defoverridable get: 3,
                     get: 4,
                     get_many: 2,
                     get_many: 3,
                     append: 2,
                     append: 3,
                     refresh: 3,
                     refresh: 4

      defp es_aggregate_repo,
        do: Map.merge(@es_aggregate_repo, %{dao: unquote(dao), codec: unquote(codec)})
    end
  end

  # ---

  defp validate_opts!(opts) do
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)

    aggregate =
      Helper.Opts.module!(opts, :aggregate, @label, exports: [__es_event_codec__: 0, fold: 2])

    event_codec = Es.Store.Opts.event_codec!(aggregate.__es_event_codec__(), @label)
    id = Helper.Opts.module!(opts, :id, @label)
    errors = Helper.Opts.module!(opts, :errors, @label, exports: [domain: 3])

    outbox =
      Helper.Opts.module!(opts, :outbox, @label, exports: [from_events: 1, __es_event__: 0])

    Es.Store.Opts.ensure_aggregate_id!(event_codec, id, @label)
    Es.Store.Opts.ensure_outbox_event!(outbox, event_codec, @label)
    Es.Store.Opts.ensure_version_mismatch!(errors, @label)

    %{
      behaviour: behaviour!(opts),
      aggregate: aggregate,
      id: id,
      event_codec: event_codec,
      type: event_codec.__es_type__(),
      errors: errors,
      outbox: outbox,
      snapshot: snapshot!(opts)
    }
  end

  defp behaviour!(opts) do
    behaviour = Helper.Opts.module!(opts, :behaviour, @label)

    case Es.Aggregate.Repo.callbacks() -- behaviour.behaviour_info(:callbacks) do
      [] ->
        behaviour

      missing ->
        raise CompileError,
          description:
            "#{@label}: behaviour #{inspect(behaviour)} должен объявлять #{inspect(missing)} " <>
              "(use Core.Es.Aggregate.Repo)"
    end
  end

  defp snapshot!(opts) do
    case Keyword.fetch(opts, :snapshot) do
      {:ok, snapshot} -> Snapshot.opts!(snapshot, @label)
      :error -> nil
    end
  end

  @doc false
  @spec get(map(), struct(), Version.expected(), Context.t(), keyword()) ::
          {:ok, struct()} | {:error, Error.t()}

  def get(cfg, id, version, %Context{}, opts) when is_version(version) and is_list(opts),
    do: load_stream(cfg, :get, struct(cfg.aggregate, id: id), version, opts)

  @doc false
  @spec get_many(map(), [{struct(), Version.expected()}], Context.t(), keyword()) ::
          {:ok, [struct()]} | {:error, Error.t()}

  def get_many(cfg, pairs, %Context{}, opts) when is_list(pairs) and is_list(opts),
    do: load(cfg, :get_many, initial_states!(cfg, pairs), opts, &verify_versions(cfg, &1, pairs))

  # ---

  defp initial_states!(%{aggregate: aggregate, id: id_mod}, pairs) do
    states =
      Enum.map(pairs, fn {%^id_mod{} = id, version} when is_version(version) ->
        struct(aggregate, id: id)
      end)

    ids = Enum.map(states, & &1.id)

    case ids -- Enum.uniq(ids) do
      [] -> states
      repeated -> raise ArgumentError, "#{@label}: повтор id в get_many: #{inspect(repeated)}"
    end
  end

  defp verify_versions(cfg, states, pairs) do
    codec = cfg.codec

    details =
      states
      |> Enum.zip(pairs)
      |> Enum.flat_map(fn {state, {_id, version}} ->
        List.wrap(mismatch_detail(state, version, codec))
      end)

    case details do
      [] -> {:ok, states}
      details -> {:error, version_mismatch(cfg, details)}
    end
  end

  @doc false
  @spec append(map(), [Es.Event.t()], Context.t(), keyword()) :: :ok | {:error, Error.t()}

  def append(cfg, events, context, opts)

  def append(_cfg, [], %Context{}, opts) when is_list(opts), do: :ok

  def append(cfg, [_ | _] = events, %Context{} = context, opts) when is_list(opts),
    do: Transact.run(cfg.dao, fn -> write(cfg, events, context, opts) end, opts)

  # ---

  defp write(cfg, events, context, opts) do
    mismatch = &version_mismatch(cfg, &1)

    with {:ok, records} <- cfg.outbox.from_events(events),
         :ok <- Es.Store.append(cfg.event_codec, events, context, mismatch, continuous?: true) do
      Config.outbox_repo().append(records, context, opts)
    end
  end

  @doc false
  @spec refresh(map(), struct(), Version.expected(), Context.t(), keyword()) ::
          {:ok, struct()} | {:error, Error.t()}

  def refresh(cfg, state, version, %Context{}, opts) when is_version(version) and is_list(opts),
    do: load_stream(cfg, :refresh, state, version, opts)

  # ---

  defp load_stream(cfg, op, state, version, opts),
    do: load(cfg, op, [state], opts, fn [state] -> verify_version(cfg, state, version) end)

  # Восстановление и сверка версий — один замер `[:es, :aggregate, :load]`; снапшоты пишутся
  # после него: вне транзакции upsert идёт сразу и в длительность чтения не входит.
  defp load(cfg, op, states, opts, verify) do
    start = System.monotonic_time()
    restored = restore(cfg, states, opts)
    result = verify.(Enum.map(restored, & &1.state))

    :telemetry.execute(
      Telemetry.event([:es, :aggregate, :load]),
      load_measurements(restored, System.monotonic_time() - start),
      %{type: cfg.type, op: op, result: result_tag(result)}
    )

    write_snapshots(cfg, restored)
    result
  end

  # Все потоки — одним запросом, от снапшота там, где он есть; потоки отвергнутых снапшотов —
  # вторым запросом целиком. Поток — `%{snapshot, state, events}`: как свёрнут, во что и сколько
  # событий свёрнуто.
  defp restore(_cfg, [], _opts), do: []

  defp restore(cfg, states, opts) do
    restored =
      cfg
      |> read_tails(states, opts)
      |> Enum.zip_with(states, &fold_tail(cfg, &2, &1))
      |> refold_rejected(cfg, opts)

    Enum.each(restored, &emit_fold(cfg, &1))
    restored
  end

  defp read_tails(%{snapshot: nil} = cfg, states, opts),
    do: Enum.map(read_streams(cfg, states, opts), &{nil, &1})

  defp read_tails(%{type: type} = cfg, states, opts) do
    marker = Snapshot.marker(cfg)

    from(s in values(streams(cfg, states), @stream_types),
      left_join: sn in Snapshot.Schema,
      on:
        sn.aggregate_type == ^type and sn.aggregate_id == s.aggregate_id and
          sn.marker == ^marker and sn.aggregate_version > s.after_version,
      left_join: e in Schema,
      on:
        e.aggregate_type == ^type and e.aggregate_id == s.aggregate_id and
          e.aggregate_version > coalesce(sn.aggregate_version, s.after_version),
      order_by: [asc: s.index, asc: e.aggregate_version],
      # Состояние снапшота — только в первой строке потока, а не в каждой строке его хвоста.
      select:
        {s.index, sn.aggregate_version,
         fragment(
           "CASE WHEN row_number() OVER (PARTITION BY ? ORDER BY ?) = 1 THEN ? END",
           s.index,
           e.aggregate_version,
           sn.state
         ), e}
    )
    |> cfg.dao.all(opts)
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.map(&tail(cfg, &1))
  end

  defp tail(cfg, [{_index, version, state, _row} | _] = rows) do
    events = for {_index, _version, _state, %Schema{} = row} <- rows, do: load_event(cfg, row)
    {stored_snapshot(version, state), events}
  end

  defp stored_snapshot(nil, nil), do: nil

  defp stored_snapshot(version, state) when is_integer(version) and is_binary(state),
    do: {version, state}

  defp read_streams(_cfg, [], _opts), do: []

  defp read_streams(cfg, states, opts) do
    events =
      from(e in Schema,
        join: s in values(streams(cfg, states), @stream_types),
        on: e.aggregate_id == s.aggregate_id and e.aggregate_version > s.after_version,
        where: e.aggregate_type == ^cfg.type,
        order_by: [asc: e.aggregate_version],
        select: {s.index, e}
      )
      |> cfg.dao.all(opts)
      |> Enum.group_by(&elem(&1, 0), &load_event(cfg, elem(&1, 1)))

    for index <- 0..(length(states) - 1)//1, do: Map.get(events, index, [])
  end

  defp streams(cfg, states) do
    states
    |> Enum.with_index()
    |> Enum.map(fn {state, index} ->
      %{index: index, aggregate_id: cfg.codec.dump(state.id), after_version: after_version(state)}
    end)
  end

  defp after_version(%{version: nil}), do: 0
  defp after_version(%{version: %Version{} = version}), do: Version.value(version)

  defp load_event(cfg, row),
    do: cfg.codec.load!(cfg.event_codec.__codec_union__(), Schema.to_wire(row))

  defp fold_tail(%{snapshot: nil} = cfg, state, {nil, events}),
    do: restored(:off, cfg.aggregate.fold(state, events), events)

  defp fold_tail(cfg, state, {nil, events}),
    do: restored(:miss, cfg.aggregate.fold(state, events), events)

  defp fold_tail(cfg, state, {snapshot, events}) do
    case Snapshot.fold(cfg, state, snapshot, events) do
      {:ok, folded} -> restored(:hit, folded, events)
      :rejected -> {:rejected, state}
    end
  end

  defp restored(snapshot, state, events),
    do: %{snapshot: snapshot, state: state, events: length(events)}

  defp refold_rejected(restored, cfg, opts) do
    rejected = for {:rejected, state} <- restored, do: state

    refolded =
      cfg
      |> read_streams(rejected, opts)
      |> Enum.zip_with(rejected, &restored(:rejected, cfg.aggregate.fold(&2, &1), &1))

    merge_refolded(restored, refolded)
  end

  defp merge_refolded([{:rejected, _state} | restored], [stream | refolded]),
    do: [stream | merge_refolded(restored, refolded)]

  defp merge_refolded([stream | restored], refolded),
    do: [stream | merge_refolded(restored, refolded)]

  defp merge_refolded([], []), do: []

  defp emit_fold(cfg, %{snapshot: snapshot, events: events}) do
    :telemetry.execute(
      Telemetry.event([:es, :aggregate, :fold]),
      %{events: events},
      %{type: cfg.type, snapshot: snapshot}
    )
  end

  defp load_measurements(restored, duration) do
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

  defp write_snapshots(%{snapshot: nil}, _restored), do: :ok

  defp write_snapshots(%{snapshot: %{every: every}} = cfg, restored) do
    states = for %{state: state, events: events} <- restored, events >= every, do: state
    Snapshot.write(cfg, states)
  end

  defp verify_version(cfg, state, version) do
    case mismatch_detail(state, version, cfg.codec) do
      nil -> {:ok, state}
      detail -> {:error, version_mismatch(cfg, detail)}
    end
  end

  defp mismatch_detail(_state, :current, _codec), do: nil

  defp mismatch_detail(%{version: version}, %Version{} = version, _codec), do: nil

  defp mismatch_detail(state, %Version{} = expected, codec) do
    %{
      aggregate_id: codec.dump(state.id),
      expected: Version.value(expected),
      actual: state.version && Version.value(state.version)
    }
  end

  defp version_mismatch(cfg, detail),
    do: cfg.errors.domain(cfg.behaviour, :version_mismatch, detail)

  defp result_tag({:ok, _}), do: :ok
  defp result_tag({:error, %Error{code: :version_mismatch}}), do: :version_mismatch
end
