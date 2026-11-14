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
  хранилища ключей `get` / `get_decision` / `get_many` / `refresh` / `get_at` / `get_many_at`
  отдают `{:error, _}`
  без замера `[:es, :aggregate, :load]`, нечитаемое событие — `Core.Exc`.

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

  Модуль ключа MUST объявлять тот же агрегат, что репозиторий: `aggregate:` ключа сверяет сборка.
  Полноту `reservation/1` по событиям агрегата проверяет сборка самого модуля ключа
  (`Core.Es.KeyReservation`, «Opts»).

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

  - `[:es, :aggregate, :load]` — на вызов `get` / `get_decision` / `get_many` / `refresh` /
    `get_at` / `get_many_at`: измерения `duration` (native, без записи снапшотов и `fun`),
    `streams`, `events`
    (свёрнутые), `snapshot_hit`, `snapshot_miss`, `snapshot_rejected` (потоки; без `snapshot:` —
    нули); метаданные `type` (тип агрегата), `op` (`:get`, `:get_decision`, `:get_many`,
    `:refresh`, `:get_at`, `:get_many_at`), `result` (`:ok`, `:version_mismatch`). У
    `get_decision` `result` — сверка до решения: пустой поток при `%Version{}` — `:ok`.
  - `[:es, :aggregate, :fold]` — на свёрнутый поток: измерение `events`; метаданные `type`,
    `op` (тот же, что у `load`), `snapshot` (`:hit`, `:miss`, `:rejected`, без `snapshot:` — `:off`).
  - `[:es, :snapshot, :write]` — на upsert снапшотов: измерения `duration` (native), `rows`
    (записанные строки, при отказе — 0); метаданные `type`, `result` (`:ok`, `:error`).

  ## Opts

  Все опции — литералы (`docs/rules/20-agreements.md`, «Опции `use`»): атрибут или вызов
  функции в опции — `CompileError` «ожидается литерал».

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
  — не список модулей ключа, у модуля ключа `aggregate:` не равен агрегату behaviour, в `errors:`
  нет clause его `code:`, область повторяется.

  Макрос занимает в вызывающем модуле имя `@es_aggregate_repo`, приватную
  `es_aggregate_repo/0` и `@doc false` `__es_aggregate_repo__/0` — полную конфигурацию чтения.
  """

  import Core.Version, only: [is_version: 1]
  import Ecto.Query

  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Es.Aggregate.Load
  alias Core.Es.Aggregate.Repo.Pg.Snapshot
  alias Core.Es.Store.Schema
  alias Core.Helper
  alias Core.Helper.Transact
  alias Core.Result
  alias Core.Version

  @label "Es.Aggregate.Repo.Pg"
  @required_keys ~w(behaviour errors outbox)a
  @optional_keys ~w(repo codec snapshot key_reservations)a
  @expression_keys []
  @stream_types %{
    index: :integer,
    aggregate_id: :binary_id,
    after_version: :integer,
    to_version: :integer,
    snapshot_to: :integer
  }

  # ===== объявление =====

  @doc "Реализовать write-репозиторий event-sourced агрегата на хранилище событий."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)
    cfg = config!(opts)
    dao = Helper.Opts.module_or_config!(opts, :repo, :dao, @label)
    codec = Helper.Opts.module_or_config!(opts, :codec, :codec, @label)

    quote generated: true do
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

      @doc false
      def __es_aggregate_repo__,
        do: Map.merge(@es_aggregate_repo, %{dao: unquote(dao), codec: unquote(codec)})

      defp es_aggregate_repo, do: __es_aggregate_repo__()
    end
  end

  # ---

  defp config!(opts) do
    behaviour = behaviour!(opts)
    %{aggregate: aggregate, id: id} = behaviour.__es_aggregate_repo__()
    event_codec = aggregate.__es_event_codec__()
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
        Es.KeyReservation.declarations!(Keyword.get(opts, :key_reservations, []), aggregate, errors, @label)
    }
  end

  defp behaviour!(opts) do
    behaviour = Helper.Opts.module!(opts, :behaviour, @label, exports: [__es_aggregate_repo__: 0])

    case Es.Aggregate.Repo.callbacks() -- behaviour.behaviour_info(:callbacks) do
      [] ->
        behaviour

      missing ->
        Helper.Opts.reject!(
          "#{@label}: behaviour",
          "#{inspect(behaviour)} должен объявлять #{inspect(missing)} (use Core.Es.Aggregate.Repo)"
        )
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

  def get(cfg, id, version, %Context{}, opts) when is_version(version) and is_list(opts) do
    request = %{
      op: :get,
      opts: opts,
      source: &fetch/3,
      write?: true,
      states: [%{state: struct(cfg.aggregate, id: id), version: version}],
      verify: fn [restored] -> verify_version(cfg, restored.state, version) end
    }

    with {:ok, [state]} <- Load.head(cfg, request), do: {:ok, state}
  end

  @doc false
  @spec get_at(map(), struct(), Version.t(), Context.t(), keyword()) :: Result.t(struct())

  def get_at(cfg, id, %Version{} = version, %Context{}, opts) when is_list(opts) do
    request = %{
      op: :get_at,
      opts: opts,
      source: &fetch/3,
      write?: false,
      state: struct(cfg.aggregate, id: id),
      verify: fn [restored] -> verify_at(cfg, restored.state, version) end
    }

    Load.at(cfg, request, version)
  end

  @doc false
  @spec get_many_at(map(), [{struct(), Version.t()}], Context.t(), keyword()) ::
          Result.t([struct()])

  def get_many_at(_cfg, [], %Context{}, opts) when is_list(opts), do: {:ok, []}

  def get_many_at(cfg, [_ | _] = pairs, %Context{}, opts) when is_list(opts) do
    request = %{
      op: :get_many_at,
      opts: opts,
      source: &fetch/3,
      write?: false,
      verify: &verify_addresses(cfg, pairs, &1)
    }

    Load.many_at(cfg, request, pairs)
  end

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
    request = %{
      op: :get_decision,
      opts: opts,
      source: &fetch/3,
      write?: true,
      states: [%{state: struct(cfg.aggregate, id: id), version: version}],
      verify: fn [restored] -> verify_born_version(cfg, restored.state, version) end
    }

    with {:ok, [state]} <- Load.head(cfg, request), do: decision(cfg, state, version, fun)
  end

  @doc false
  @spec get_many(map(), [{struct(), Version.expected()}], Context.t(), keyword()) ::
          Result.t([struct()])

  def get_many(cfg, pairs, %Context{}, opts) when is_list(pairs) and is_list(opts) do
    request = %{
      op: :get_many,
      opts: opts,
      source: &fetch/3,
      write?: true,
      states: initial_states!(cfg, pairs),
      verify: fn restored -> verify_versions(cfg, restored, pairs) end
    }

    Load.head(cfg, request)
  end

  @doc false
  @spec refresh(map(), struct(), Version.expected(), Context.t(), keyword()) ::
          Result.t(struct())

  def refresh(cfg, state, version, %Context{}, opts) when is_version(version) and is_list(opts) do
    request = %{
      op: :refresh,
      opts: opts,
      source: &fetch/3,
      write?: true,
      states: [%{state: state, version: version}],
      verify: fn [restored] -> verify_version(cfg, restored.state, version) end
    }

    with {:ok, [state]} <- Load.head(cfg, request), do: {:ok, state}
  end

  # ---

  defp initial_states!(%{aggregate: aggregate, id: id_mod}, pairs) do
    states =
      Enum.map(pairs, fn {%^id_mod{} = id, version} when is_version(version) ->
        %{state: struct(aggregate, id: id), version: version}
      end)

    ids = Enum.map(states, & &1.state.id)

    case ids -- Enum.uniq(ids) do
      [] -> states
      repeated -> raise ArgumentError, "#{@label}: повтор id в get_many: #{inspect(repeated)}"
    end
  end

  defp verify_versions(cfg, restored, pairs) do
    by_id = Map.new(restored, &{&1.state.id, &1})
    id_mod = cfg.id

    results =
      Enum.map(pairs, fn {%^id_mod{} = id, version} ->
        state = Map.fetch!(by_id, id).state

        case mismatch_detail(state, version, cfg.codec) do
          nil -> {:ok, state}
          detail -> {:error, detail}
        end
      end)

    case for {:error, detail} <- results, do: detail do
      [] -> {:ok, for({:ok, state} <- results, do: state)}
      details -> {:error, version_mismatch(cfg, details)}
    end
  end

  # Состояние каждой пары — снятие состояния на её версии; нет состояния на версии — адрес за
  # головой потока или на пустом потоке. Расхождения собираются в одну ошибку в порядке пар.
  defp verify_addresses(cfg, pairs, restored) do
    by_id = Map.new(restored, &{&1.state.id, &1})
    id_mod = cfg.id

    results =
      Enum.map(pairs, fn {%^id_mod{} = id, %Version{} = version} ->
        expected = Version.value(version)
        stream = Map.fetch!(by_id, id)

        case Map.fetch(stream.captures, expected) do
          {:ok, state} -> {:ok, state}
          :error -> {:error, address_detail(cfg, stream.state, expected)}
        end
      end)

    case for {:error, detail} <- results, do: detail do
      [] -> {:ok, for({:ok, state} <- results, do: state)}
      details -> {:error, version_mismatch(cfg, details)}
    end
  end

  # Пустой поток при `%Version{}` — не гонка, а ссылка на состояние, которого не было: отказ или
  # принятие решает `fun` на незаведённом агрегате (ADR-0016).
  defp verify_born_version(_cfg, %{version: nil} = state, _version), do: {:ok, [state]}
  defp verify_born_version(cfg, state, version), do: verify_version(cfg, state, version)

  defp decision(cfg, %{version: nil} = state, %Version{} = version, fun) do
    case fun.(state) do
      {:ok, _decision} -> {:error, version_mismatch(cfg, mismatch_detail(state, version, cfg.codec))}
      {:error, _reason} = error -> error
    end
  end

  defp decision(_cfg, state, _version, fun), do: fun.(state)

  defp verify_version(cfg, state, version) do
    case mismatch_detail(state, version, cfg.codec) do
      nil -> {:ok, [state]}
      detail -> {:error, version_mismatch(cfg, detail)}
    end
  end

  # Адрес версии — ссылка на состояние, которого в потоке нет: пустой поток или версия за его
  # головой. Это не гонка записи, поэтому `source: :address`, и `Es.Transact` отказ не повторяет.
  defp verify_at(_cfg, %{version: head} = state, %Version{} = version) when head == version,
    do: {:ok, state}

  defp verify_at(cfg, state, %Version{} = version),
    do: {:error, version_mismatch(cfg, address_detail(cfg, state, Version.value(version)))}

  defp address_detail(cfg, state, expected) do
    %{
      aggregate_id: cfg.codec.dump(state.id),
      expected: expected,
      actual: state.version && Version.value(state.version),
      source: :address
    }
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

  # ===== источник строк =====

  @doc false
  @spec fetch(map(), [Load.meta()], keyword()) :: [Load.triple()]

  def fetch(%{snapshot: nil} = cfg, metas, opts), do: read_streams(cfg, metas, opts)

  def fetch(cfg, metas, opts) do
    streams =
      metas
      |> snapshot_streams(cfg.type, Snapshot.marker(cfg))
      |> cfg.dao.all(opts)
      |> Enum.chunk_by(&elem(&1, 0))
      |> Map.new(fn [row | _] = stream -> {elem(row, 0), stream} end)

    for {meta, index} <- Enum.with_index(metas) do
      stream = Map.get(streams, index, [])
      {meta, stored_snapshot(stream), event_rows(stream)}
    end
  end

  # ---

  defp snapshot_streams(metas, type, marker) do
    from(s in values(streams(metas), @stream_types),
      left_join: sn in Snapshot.Schema,
      on:
        sn.aggregate_type == ^type and sn.aggregate_id == s.aggregate_id and
          sn.marker == ^marker and sn.aggregate_version > s.after_version and
          (is_nil(s.snapshot_to) or sn.aggregate_version <= s.snapshot_to)
    )
    |> join_tail(type)
  end

  defp join_tail(query, type) do
    from([s, sn] in query,
      left_join: e in Schema,
      on:
        e.aggregate_type == ^type and e.aggregate_id == s.aggregate_id and
          e.aggregate_version > coalesce(sn.aggregate_version, s.after_version) and
          (is_nil(s.to_version) or e.aggregate_version <= s.to_version),
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
  end

  # У потока без событий после снапшота или состояния одна строка, и событие в ней — `nil`
  # (`left_join`).
  defp event_rows(stream), do: for({_index, _version, _state, %Schema{} = row} <- stream, do: row)

  defp stored_snapshot([]), do: nil
  defp stored_snapshot([{_index, nil, nil, _row} | _rows]), do: nil

  defp stored_snapshot([{_index, version, state, _row} | _rows]) when is_integer(version) and is_binary(state),
    do: {version, state}

  defp read_streams(_cfg, [], _opts), do: []

  defp read_streams(cfg, metas, opts) do
    rows =
      from(e in Schema,
        join: s in values(streams(metas), @stream_types),
        on: e.aggregate_id == s.aggregate_id and e.aggregate_version > s.after_version,
        where:
          e.aggregate_type == ^cfg.type and
            (is_nil(s.to_version) or e.aggregate_version <= s.to_version),
        order_by: [asc: e.aggregate_version],
        select: {s.index, e}
      )
      |> cfg.dao.all(opts)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    for {meta, index} <- Enum.with_index(metas), do: {meta, nil, Map.get(rows, index, [])}
  end

  defp streams(metas) do
    metas
    |> Enum.with_index()
    |> Enum.map(fn {meta, index} ->
      %{
        index: index,
        aggregate_id: meta.aggregate_id,
        after_version: meta.after_version,
        to_version: meta.to_version,
        # Отвергнутый снапшот читается без join'а: потолок снапшота — его же начало.
        snapshot_to: if(meta.snapshot?, do: meta.snapshot_to, else: meta.after_version)
      }
    end)
  end

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
