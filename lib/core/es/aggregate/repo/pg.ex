defmodule Core.Es.Aggregate.Repo.Pg do
  @moduledoc """
  Билдер write-репозитория event-sourced агрегата на хранилище событий (`Core.Es.Store`).

      defmodule MyApp.Domain.<BC>.Account.Repo.Pg do
        alias MyApp.Domain.<BC>.Account

        use Core.Es.Aggregate.Repo.Pg,
          behaviour: MyApp.Domain.<BC>.Account.Repo,
          errors: Account.Errors,
          outbox: Account.Outbox
      end

  Строки состояния нет: `get` / `get_decision` / `get_many` / `refresh` сворачивают события потока
  через `Agg.fold/2`. Агрегат и Prim идентификатора — из `__es_aggregate_repo__/0` behaviour, тип
  агрегата и семейство событий — из кодека `__es_event_codec__/0` агрегата.
  `Repo.Sc`, `default_filters` и `delete` не участвуют: доступ решают usecase и `decide`,
  удаление — доменное событие.

  ## Генерируемые функции

  - `get(id, version, context, opts)` — пустой поток — `%Agg{id: id, version: nil}`, а не
    `:not_found`: существование агрегата решает `decide`. `%Version{}`, не равная голове потока
    после свёртки, — `:version_mismatch`, у пустого потока `actual: nil`.
  - `get_decision(id, version, context, fun, opts)` — читающая, `fun: state -> {:ok, decision} |
    {:error, reason}` (ADR-0016): версия сошлась или `:current` — `fun.(state)`, у пустого потока
    при `:current` — от `%Agg{id: id, version: nil}`; пустой поток при `%Version{}` —
    `fun.(незаведённый)`, `{:error, _}` отдаётся как есть, `{:ok, _}` становится
    `:version_mismatch` с `actual: nil`; непустой поток мимо версии — `:version_mismatch`, `fun`
    не вызывается. Возврат `fun` вне `{:ok, _} | {:error, _}` — `CaseClauseError`.
  - `get_many(pairs, context, opts)` — все потоки одним запросом, состояния в порядке пар `{id,
    version}`; все расхождения — одна `:version_mismatch` со списком detail в порядке пар; `[]` —
    `{:ok, []}` без запросов; повтор id — `ArgumentError`.
  - `append(events, context, opts)` — `[]` — `:ok` без запросов; иначе в
    `Core.Helper.Transact.run/3` — запись событий и outbox `Core.Es.Store.Write` с непрерывностью
    потока и резервами ключей `key_reservations:`.
    События нескольких потоков одного типа пишутся пачкой, отказ в любом потоке откатывает всю;
    событие не из `tags:` кодека — `FunctionClauseError`.
  - `refresh(state, version, context, opts)` — события потока после `state.version`, свёрнутые
    от `state`; `version` сверяется, как у `get`.
  - `page_stream(id, limit, offset, context)` — страница потока агрегата по возрастанию версии,
    `total` — весь поток: пустой поток — страница с `total: 0`, первая ошибка загрузки —
    `{:error, _}` на всю страницу. Реализация и исходы — `Core.Es.Store`, «Страница потока».

  ПДн-значения событий чтение расшифровывает пакетом (`Core.Es.Store`, «Загрузка пачки»): сбой
  хранилища ключей `get` / `get_decision` / `get_many` / `refresh` отдают `{:error, _}` без замера
  `[:es, :aggregate, :load]`, нечитаемое событие — `Core.Exc`.

  `opts` — опции запроса и транзакции, у `page_stream` их нет. Функции `defoverridable`.

  Головы принимают только `%Agg.ID{}` и `%Agg{}`, результат сужен паттерном: `get` / `refresh` —
  `{:ok, %Agg{}} | {:error, _}`, `get_decision` — `{:ok, _} | {:error, _}`, `get_many` —
  `{:ok, list} | {:error, _}`, `append` — `:ok | {:error, _}`, `page_stream` —
  `{:ok, %Core.Pagination.Result{}} | {:error, _}`. Компилятор у вызывающего знает состояние
  агрегата и страницу, и ID другого агрегата, опечатка в поле или невозможная clause по результату
  — предупреждение при сборке; элементы списков `get_many` и страницы, состояние в `fun` и решение
  `get_decision` он не видит.

  `:version_mismatch` — `errors.domain(behaviour, :version_mismatch, detail)`, detail —
  `%{aggregate_id, expected, actual, source}` (`t:Core.Es.Store.mismatch_detail/0`): у `append`
  его строит хранилище с `source: :storage`, у чтения `expected` — значение `version`, `actual` —
  версия после свёртки, `source: :expected`. По `source:` решается повтор команды
  (`Core.Es.Transact`): отказ хранилища снимается повтором, сверка ожидаемой версии — нет.

  Нечитаемый поток у `get` / `get_decision` / `get_many` / `refresh` — исключение: неизвестный
  тег — `Core.Exc` загрузки кодеком событий, разрыв версий — `ArgumentError` из `Agg.fold/2`.
  `page_stream` отдаёт ошибку загрузки `{:error, _}` на всю страницу.

  ## Резервы ключей

  `key_reservations: [User.LoginKey]` — модули изменяемых уникальных ключей агрегата
  (`use Core.Es.KeyReservation`, `docs/adr/0018-mutable-key-reservation.md`). `append` держит их
  резервы в `es_key_reservations` той же транзакцией, после записи событий: конкурентная команда
  того же потока получает `:version_mismatch` до резервов. Ключ, занятый другим агрегатом, —
  `errors.domain(behaviour, code, %{scope: scope})` с `code:` модуля ключа, события не записаны.
  Исходы резерва — `Core.Es.KeyReservation`, «Резерв»; модуль ключа из ПДн (`personal: true`) —
  там же, «Ключ из ПДн»: сбой хранилища ключей на его индексе — `{:error, _}` без записи.

  Сборка проверяет `reservation/1` модулей ключа по кодеку агрегата: на каждое событие макрос
  генерирует функцию-проверку (`Core.Es.Check`) `"reservation/1 принимает <Event>"` — литеральный
  вызов `Key.reservation(%Event.Mod{payload: %Payload{}} = event)` каждого модуля ключа.
  Событие без clause и опечатка в поле нагрузки, не суженной паттерном, — предупреждение на строке
  `use`.

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
  - Агрегат с ПДн в событиях (`__es_subjects__/0` кодека не пуст): `snapshot:` — только если у
    всех ПДн-полей `subject: :aggregate_id`. Снапшот шифруется всегда — `term_to_binary` состояния
    одним ПДн-значением субъекта `aggregate_id` через порт хранилища ключей, AAD — тип, id, версия
    и маркер; признак входит в маркер. Шифротексты снапшотов расшифровываются тем же вызовом
    `open`, что и ПДн-значения хвоста: ключ уничтожен — отказ на `debug` и полная свёртка,
    шифротекст не открылся — отказ на `warning` и полная свёртка, сбой хранилища — `{:error, _}`.
    Запись шифрует одним `seal` после commit; `:subject_destroyed` — снапшот не пишется, лог
    `debug`. Чтение, видевшее уничтоженный снапшот или ПДн-значение, снапшот потока не пишет.

  ## Telemetry

  Имена — `Core.Telemetry.event/1`; span'а у восстановления нет, на нечитаемом потоке события
  не шлются.

  - `[:es, :aggregate, :load]` — на вызов `get` / `get_decision` / `get_many` / `refresh`:
    измерения `duration` (native, без записи снапшотов и `fun`), `streams`, `events` (свёрнутые),
    `snapshot_hit`, `snapshot_miss`, `snapshot_rejected` (потоки; без `snapshot:` — нули);
    метаданные `type` (тип агрегата), `op` (`:get`, `:get_decision`, `:get_many`, `:refresh`),
    `result` (`:ok`, `:version_mismatch`). У `get_decision` `result` — сверка до решения: пустой
    поток при `%Version{}` — `:ok`.
  - `[:es, :aggregate, :fold]` — на свёрнутый поток: измерение `events`; метаданные `type`,
    `snapshot` (`:hit`, `:miss`, `:rejected`, без `snapshot:` — `:off`).
  - `[:es, :snapshot, :write]` — на upsert снапшотов: измерения `duration` (native), `rows`
    (записанные строки, при отказе — 0); метаданные `type`, `result` (`:ok`, `:error`).

  ## Opts

  - `behaviour:` — `use Core.Es.Aggregate.Repo`; модуль ошибок `:version_mismatch`, источник агрегата
    и Prim идентификатора
  - `errors:` — каталог ошибок с clause `:version_mismatch`
  - `outbox:` — `<Aggregate>.Outbox` (`use Core.Es.Outbox`) либо `:none`: агрегат не публикует
    события наружу, записей outbox нет
  - `repo:` — Ecto-репозиторий транзакции `append` и восстановления состояния (`get` /
    `get_decision` / `get_many` / `refresh`); по умолчанию `Core.Config.dao/0` в рантайме. Сами
    события `Core.Es.Store.append/5` пишет, а страницу потока `page_stream` читает через
    `Core.Config.dao/0`
  - `codec:` — фасад дампа id и вложенных значений событий при восстановлении состояния; по умолчанию
    `Core.Config.codec/0` в рантайме. Страница потока грузится через `Core.Config.codec/0`
  - `snapshot:` — `[every: N, version: V]`, без опции снапшоты выключены: `every:` — сколько
    свёрнутых событий потока дают запись снапшота, целое больше нуля, обязательна; `version:` —
    ручная часть маркера, целое, по умолчанию 1
  - `key_reservations:` — список модулей ключа (`use Core.Es.KeyReservation`), по умолчанию `[]`

  На компиляции `CompileError`, если `behaviour:` — не `use Core.Es.Aggregate.Repo` (нет
  `__es_aggregate_repo__/0` или колбэков), и на сверках `Core.Es.Store.Opts`: кодек агрегата без
  `type:`, семейство кодека называет владельцем потока не агрегат behaviour, событие `outbox:` не
  равно семейству кодека, в `errors:` нет clause `:version_mismatch`; `snapshot:` —
  не keyword, без `every:`, с неизвестной опцией, `every:` не целое больше нуля, `version:` не
  целое или у ПДн-поля события субъект — поле нагрузки, а не `:aggregate_id`; `key_reservations:`
  — не список модулей ключа, у модуля ключа событие не равно семейству кодека или `id:` — `id:`
  репозитория, в `errors:` нет clause его `code:`, область повторяется.

  Макрос занимает в вызывающем модуле имя `@es_aggregate_repo`, приватную `es_aggregate_repo/0` и,
  с `key_reservations:`, имена функций-проверок `"reservation/1 принимает <Event>"/1`.
  """

  import Core.Version, only: [is_version: 1]
  import Ecto.Query

  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Es.Aggregate.Repo.Pg.Snapshot
  alias Core.Es.Personal.Destroyed
  alias Core.Es.Store.Schema
  alias Core.Helper
  alias Core.Helper.Transact
  alias Core.Result
  alias Core.Telemetry
  alias Core.Version

  @label "Es.Aggregate.Repo.Pg"
  @required_keys ~w(behaviour errors outbox)a
  @optional_keys ~w(repo codec snapshot key_reservations)a
  @stream_types %{index: :integer, aggregate_id: :binary_id, after_version: :integer}

  # ===== объявление =====

  @doc "Реализовать write-репозиторий event-sourced агрегата на хранилище событий."
  defmacro __using__(opts) do
    lit = Macro.expand_literals(opts, __CALLER__)
    cfg = validate_opts!(lit)
    dao = Helper.Opts.module_or_config!(lit, :repo, :dao, @label)
    codec = Helper.Opts.module_or_config!(lit, :codec, :codec, @label)
    checks = Es.KeyReservation.checks(cfg.key_reservations, cfg.event_codec, __CALLER__.line)

    quote generated: true do
      unquote_splicing(checks)

      @behaviour unquote(cfg.behaviour)

      @es_aggregate_repo unquote(Macro.escape(cfg))

      import Core.Version, only: [is_version: 1]

      @doc "Состояние агрегата из его потока; `version` сверяется с головой потока."
      @impl true
      def get(%unquote(cfg.id){} = id, version, %Core.Context{} = context, opts \\ [])
          when is_version(version) and is_list(opts) do
        case Core.Es.Aggregate.Repo.Pg.get(es_aggregate_repo(), id, version, context, opts) do
          {:ok, %unquote(cfg.aggregate){} = state} -> {:ok, state}
          {:error, reason} -> {:error, reason}
        end
      end

      @doc "Решение `fun` над состоянием агрегата; явная версия на пустом потоке сверяется после решения."
      @impl true
      def get_decision(%unquote(cfg.id){} = id, version, %Core.Context{} = context, fun, opts \\ [])
          when is_version(version) and is_function(fun, 1) and is_list(opts) do
        case Core.Es.Aggregate.Repo.Pg.get_decision(es_aggregate_repo(), id, version, context, fun, opts) do
          {:ok, decision} -> {:ok, decision}
          {:error, reason} -> {:error, reason}
        end
      end

      @doc "Состояния агрегатов по парам `{id, version}` одним запросом, в порядке пар."
      @impl true
      def get_many(pairs, %Core.Context{} = context, opts \\ [])
          when is_list(pairs) and is_list(opts) do
        case Core.Es.Aggregate.Repo.Pg.get_many(es_aggregate_repo(), pairs, context, opts) do
          {:ok, states} when is_list(states) -> {:ok, states}
          {:error, reason} -> {:error, reason}
        end
      end

      @doc "Записать события агрегатов в хранилище событий и outbox одной транзакцией."
      @impl true
      def append(events, %Core.Context{} = context, opts \\ [])
          when is_list(events) and is_list(opts) do
        case Core.Es.Aggregate.Repo.Pg.append(es_aggregate_repo(), events, context, opts) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end
      end

      @doc "Дочитать поток после `state.version`; `version` сверяется с головой потока."
      @impl true
      def refresh(
            %unquote(cfg.aggregate){} = state,
            version,
            %Core.Context{} = context,
            opts \\ []
          )
          when is_version(version) and is_list(opts) do
        case Core.Es.Aggregate.Repo.Pg.refresh(es_aggregate_repo(), state, version, context, opts) do
          {:ok, %unquote(cfg.aggregate){} = refreshed} -> {:ok, refreshed}
          {:error, reason} -> {:error, reason}
        end
      end

      @doc "Страница потока агрегата по возрастанию версии; `total` — весь поток."
      @impl true
      def page_stream(
            %unquote(cfg.id){} = id,
            %Core.Pagination.Limit{} = limit,
            %Core.Pagination.Offset{} = offset,
            %Core.Context{} = context
          ) do
        case Core.Es.Store.read_stream(unquote(cfg.event_codec), id, limit, offset, context) do
          {:ok, %Core.Pagination.Result{} = page} -> {:ok, page}
          {:error, reason} -> {:error, reason}
        end
      end

      defoverridable get: 3,
                     get: 4,
                     get_decision: 4,
                     get_decision: 5,
                     get_many: 2,
                     get_many: 3,
                     append: 2,
                     append: 3,
                     refresh: 3,
                     refresh: 4,
                     page_stream: 4

      defp es_aggregate_repo,
        do: Map.merge(@es_aggregate_repo, %{dao: unquote(dao), codec: unquote(codec)})
    end
  end

  # ---

  defp validate_opts!(opts) do
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)

    behaviour = behaviour!(opts)
    %{aggregate: aggregate, id: id} = behaviour.__es_aggregate_repo__()
    event_codec = Es.Store.Opts.event_codec!(aggregate.__es_event_codec__(), @label)
    Es.Store.Opts.ensure_family_aggregate!(event_codec, aggregate, @label)
    errors = Helper.Opts.module!(opts, :errors, @label, exports: [domain: 3])

    outbox = Es.Store.Opts.outbox!(opts, event_codec, @label)

    Es.Store.Opts.ensure_version_mismatch!(errors, @label)

    %{
      behaviour: behaviour,
      aggregate: aggregate,
      id: id,
      event_codec: event_codec,
      type: event_codec.__es_type__(),
      errors: errors,
      outbox: outbox,
      snapshot: snapshot!(opts, event_codec),
      key_reservations:
        Es.KeyReservation.declarations!(Keyword.get(opts, :key_reservations, []), event_codec, id, errors, @label)
    }
  end

  defp behaviour!(opts) do
    behaviour = Helper.Opts.module!(opts, :behaviour, @label, exports: [__es_aggregate_repo__: 0])

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

  defp snapshot!(opts, event_codec) do
    case Keyword.fetch(opts, :snapshot) do
      {:ok, snapshot} -> Snapshot.opts!(snapshot, event_codec.__es_subjects__(), @label)
      :error -> nil
    end
  end

  # ===== чтение =====

  @doc false
  @spec get(map(), struct(), Version.expected(), Context.t(), keyword()) ::
          Result.t(struct())

  def get(cfg, id, version, %Context{}, opts) when is_version(version) and is_list(opts),
    do: load_stream(cfg, :get, struct(cfg.aggregate, id: id), version, opts)

  @doc false
  @spec get_decision(
          map(),
          struct(),
          Version.expected(),
          Context.t(),
          (struct() -> Result.t(decision, reason)),
          keyword()
        ) :: Result.t(decision, reason | Error.t())
        when decision: var, reason: var

  def get_decision(cfg, id, version, %Context{}, fun, opts)
      when is_version(version) and is_function(fun, 1) and is_list(opts) do
    verify = fn [state] -> verify_born_version(cfg, state, version) end

    with {:ok, state} <- load(cfg, :get_decision, [struct(cfg.aggregate, id: id)], opts, verify),
         do: decision(cfg, state, version, fun)
  end

  @doc false
  @spec get_many(map(), [{struct(), Version.expected()}], Context.t(), keyword()) ::
          Result.t([struct()])

  def get_many(cfg, pairs, %Context{}, opts) when is_list(pairs) and is_list(opts),
    do: load(cfg, :get_many, initial_states!(cfg, pairs), opts, &verify_versions(cfg, &1, pairs))

  @doc false
  @spec refresh(map(), struct(), Version.expected(), Context.t(), keyword()) ::
          Result.t(struct())

  def refresh(cfg, state, version, %Context{}, opts) when is_version(version) and is_list(opts),
    do: load_stream(cfg, :refresh, state, version, opts)

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

  defp load_stream(cfg, op, state, version, opts),
    do: load(cfg, op, [state], opts, fn [state] -> verify_version(cfg, state, version) end)

  # Пустой поток при `%Version{}` — не гонка, а ссылка на состояние, которого не было: отказ или
  # принятие решает `fun` на незаведённом агрегате (ADR-0016).
  defp verify_born_version(_cfg, %{version: nil} = state, _version), do: {:ok, state}
  defp verify_born_version(cfg, state, version), do: verify_version(cfg, state, version)

  defp decision(cfg, %{version: nil} = state, %Version{} = version, fun) do
    case fun.(state) do
      {:ok, _decision} -> {:error, version_mismatch(cfg, mismatch_detail(state, version, cfg.codec))}
      {:error, _reason} = error -> error
    end
  end

  defp decision(_cfg, state, _version, fun), do: fun.(state)

  # Восстановление и сверка версий — один замер `[:es, :aggregate, :load]`; снапшоты пишутся
  # после него: вне транзакции upsert идёт сразу и в длительность чтения не входит.
  # Сбой хранилища ключей отдаётся вызывающему без замера: потоки не восстановлены.
  defp load(cfg, op, states, opts, verify) do
    start = System.monotonic_time()

    with {:ok, restored} <- restore(cfg, states, opts) do
      result = verify.(Enum.map(restored, & &1.state))

      :telemetry.execute(
        Telemetry.event([:es, :aggregate, :load]),
        load_measurements(restored, System.monotonic_time() - start),
        %{type: cfg.type, op: op, result: result_tag(result)}
      )

      write_snapshots(cfg, restored)
      result
    end
  end

  # Все потоки — одним запросом, от снапшота там, где он есть; потоки отвергнутых снапшотов —
  # вторым запросом целиком. Поток — `%{snapshot, state, events}`: как свёрнут, во что и сколько
  # событий свёрнуто.
  defp restore(_cfg, [], _opts), do: {:ok, []}

  defp restore(cfg, states, opts) do
    with {:ok, tails} <- read_tails(cfg, states, opts),
         {:ok, restored} <- refold_rejected(Enum.zip_with(tails, states, &fold_tail(cfg, &2, &1)), cfg, opts) do
      Enum.each(restored, &emit_fold(cfg, &1))
      {:ok, restored}
    end
  end

  defp read_tails(%{snapshot: nil} = cfg, states, opts) do
    with {:ok, streams} <- read_streams(cfg, states, opts), do: {:ok, Enum.map(streams, &{nil, &1, false})}
  end

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
    |> tails(cfg, states, marker)
  end

  # У потока без событий после снапшота или состояния одна строка, и событие в ней — `nil`
  # (`left_join`). Шифротексты снапшотов расшифровываются тем же вызовом `open`, что и хвост.
  defp tails(streams, cfg, states, marker) do
    snapshots = Enum.map(streams, &stored_snapshot/1)
    sealed = Snapshot.sealed(cfg, marker, states, snapshots)

    with {:ok, {loaded, opened}} <- load_streams(cfg, Enum.map(streams, &event_rows/1), sealed) do
      {:ok, Enum.zip_with(Snapshot.put_opened(cfg, snapshots, opened), loaded, &{&1, &2, destroyed_value?(cfg, &2)})}
    end
  end

  defp event_rows(stream), do: for({_index, _version, _state, %Schema{} = row} <- stream, do: row)

  defp stored_snapshot([{_index, nil, nil, _row} | _rows]), do: nil

  defp stored_snapshot([{_index, version, state, _row} | _rows]) when is_integer(version) and is_binary(state),
    do: {version, state}

  defp read_streams(_cfg, [], _opts), do: {:ok, []}

  defp read_streams(cfg, states, opts) do
    rows =
      from(e in Schema,
        join: s in values(streams(cfg, states), @stream_types),
        on: e.aggregate_id == s.aggregate_id and e.aggregate_version > s.after_version,
        where: e.aggregate_type == ^cfg.type,
        order_by: [asc: e.aggregate_version],
        select: {s.index, e}
      )
      |> cfg.dao.all(opts)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    streams = for index <- 0..(length(states) - 1)//1, do: Map.get(rows, index, [])

    with {:ok, {loaded, []}} <- load_streams(cfg, streams, []), do: {:ok, loaded}
  end

  # Строки всех потоков запроса — одной пачкой; события раскладываются обратно по потокам.
  defp load_streams(cfg, streams, sealed) do
    with {:ok, {events, opened}} <-
           Es.Store.load_fold_rows(Enum.concat(streams), cfg.event_codec, cfg.codec, sealed) do
      {loaded, []} = Enum.map_reduce(streams, events, &Enum.split(&2, length(&1)))
      {:ok, {loaded, opened}}
    end
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

  defp fold_tail(%{snapshot: nil} = cfg, state, {nil, events, _destroyed?}),
    do: restored(:off, cfg.aggregate.fold(state, events), events, false)

  defp fold_tail(cfg, state, {nil, events, destroyed?}),
    do: restored(:miss, cfg.aggregate.fold(state, events), events, destroyed?)

  defp fold_tail(cfg, state, {snapshot, events, destroyed?}) do
    case Snapshot.fold(cfg, state, snapshot, events) do
      {:ok, folded} -> restored(:hit, folded, events, destroyed?)
      :rejected -> {:rejected, state, false}
      :destroyed -> {:rejected, state, true}
    end
  end

  # `destroyed?` — чтение видело уничтоженный снапшот или ПДн-значение: снапшот потока не пишется.
  defp restored(snapshot, state, events, destroyed?),
    do: %{snapshot: snapshot, state: state, events: length(events), destroyed?: destroyed?}

  defp refold_rejected(restored, cfg, opts) do
    rejected = for {:rejected, state, destroyed?} <- restored, do: {state, destroyed?}

    with {:ok, streams} <- read_streams(cfg, Enum.map(rejected, &elem(&1, 0)), opts) do
      refolded =
        Enum.zip_with(streams, rejected, fn events, {state, destroyed?} ->
          restored(:rejected, cfg.aggregate.fold(state, events), events, destroyed? or destroyed_value?(cfg, events))
        end)

      {:ok, merge_refolded(restored, refolded)}
    end
  end

  # Поле с `subject:` — только на верхнем уровне нагрузки.
  defp destroyed_value?(%{snapshot: %{sealed: false}}, _events), do: false

  defp destroyed_value?(_cfg, events) do
    Enum.any?(events, fn
      %{payload: %_{} = payload} -> Enum.any?(Map.from_struct(payload), &match?({_field, %Destroyed{}}, &1))
      _event -> false
    end)
  end

  defp merge_refolded([{:rejected, _state, _destroyed?} | restored], [stream | refolded]),
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
    states = for %{state: state, events: events, destroyed?: false} <- restored, events >= every, do: state
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
      actual: state.version && Version.value(state.version),
      source: :expected
    }
  end

  defp result_tag({:ok, _}), do: :ok
  defp result_tag({:error, %Error{code: :version_mismatch}}), do: :version_mismatch

  # ===== запись =====

  @doc false
  @spec append(map(), [Es.Event.t()], Context.t(), keyword()) :: Result.unit()

  def append(cfg, events, context, opts)

  def append(_cfg, [], %Context{}, opts) when is_list(opts), do: :ok

  def append(cfg, [_ | _] = events, %Context{} = context, opts) when is_list(opts),
    do: Transact.run(cfg.dao, fn -> Es.Store.Write.append(write_path(cfg), events, context, opts) end, opts)

  # ---

  defp write_path(cfg) do
    %{
      event_codec: cfg.event_codec,
      outbox: cfg.outbox,
      mismatch: &version_mismatch(cfg, &1),
      continuous?: true,
      key_reservations: cfg.key_reservations,
      taken: &cfg.errors.domain(cfg.behaviour, &1, &2)
    }
  end

  # ===== общее =====

  defp version_mismatch(cfg, detail),
    do: cfg.errors.domain(cfg.behaviour, :version_mismatch, detail)
end
