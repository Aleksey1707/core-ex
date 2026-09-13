# Готовые решения: контракт агрегата и снапшоты

## Вопрос

Тикет: [04-research-aggregate-snapshots](../issues/04-research-aggregate-snapshots.md). Как в Commanded, Marten,
Emmett и Message DB / Eventide объявлены обработка команды и применение события (чистота, пустой поток, кто
поднимает версию), как команда получает состояние, как устроены снапшоты (хранение, политика, формат, версия
схемы, инвалидация, нечитаемый снапшот) и как тестируют агрегат.

Срез: Commanded `936dbb1` (mix.exs 1.4.11, 2026-07-27), EventStore `930f921` (1.4.8), Marten `3e56e4f`
(9.33.0, 2026-09-12), Emmett `d1882f6` (0.43.0-beta.44, 2026-09-11), Eventide docs `913c3ce`, entity-store
`f551413`, entity-cache `e9e068e`, entity-snapshot-postgres `b903b65`, message-db `25da82b`.
**Вывод из кода** — факт прочитан в исходнике, в документации не описан.

## Commanded

**Контракт.** Агрегат — модуль со struct; `@behaviour Commanded.Aggregates.Aggregate` задаёт `execute/2`
(optional) и `apply/2` [2, L124–132]. `execute` возвращает событие, список, `{:ok, _}`, `:ok` / `nil` / `[]`
или `{:error, _}`, допустим `raise` [1]. `apply/2` «**MUST NOT** fail», потому что используется при
пересборке из истории [1]. Слова «pure» в гайде нет; требование — данные чужого агрегата брать из проекции
и класть в команду до dispatch [1]. Несколько событий, зависящих от промежуточного состояния, —
`Commanded.Aggregate.Multi` [1].

```elixir
def execute(%ExampleAggregate{uuid: nil}, %Create{} = command) do
  %Create{uuid: uuid, name: name} = command
  {:ok, %Created{uuid: uuid, name: name}}
end

def apply(%ExampleAggregate{}, %Created{uuid: uuid, name: name}),
  do: %ExampleAggregate{uuid: uuid, name: name}
```

**Пустой поток** — `struct(aggregate_module)`, `aggregate_version: 0` [3, L56–74].

**Версия** — не в struct агрегата, а в состоянии процесса: после append
`aggregate_version = expected_version + length(pending_events)`; на `{:error, :wrong_expected_version}` процесс
дочитывает события и повторяет команду, если `ExecutionContext.retry` разрешает [2, L556–590].

**Получение состояния.** Агрегат — `GenServer` на экземпляр, команды к нему сериализуются, по умолчанию
процесс живёт бесконечно (`AggregateLifespan`) [2, moduledoc]. В `handle_continue` состояние поднимается из
снапшота (если он есть и валиден), затем события с `aggregate_version + 1` батчами по 1000 [3]. Живой процесс
применяет новые события из подписки при `stream_version == aggregate_version + 1` [2, L433–455]. Кэш — процесс
в памяти, снапшот ускоряет холодный старт.

**Снапшоты.**

- Включаются в конфиге per-aggregate, по умолчанию выключены [1]:

  ```elixir
  config :my_app, MyApp.Application,
    snapshotting: %{MyApp.ExampleAggregate => [snapshot_every: 10, snapshot_version: 1]}
  ```

- **Политика.** После команды при `aggregate_version - snapshot_version >= snapshot_every` процесс шлёт себе
  `{:take_snapshot, _}` и снимает снапшот после ответа вызывающему, вне транзакции append
  [2, L341–353, L404–413; 4, L63–69]. Сбой записи — `Logger.warning`, работа продолжается [2, L617–632].
  Вывод из кода: `populate` не выставляет счётчик `snapshot_version` в `%Snapshotting{}` [3, L62–66], поэтому
  после рестарта процесса первая команда агрегата с версией ≥ `snapshot_every` снимает снапшот заново.
- **Хранение** (EventStore): таблица `snapshots` — `source_uuid` PK, `source_version`, `source_type`, `data`,
  `metadata`, `created_at`; запись `INSERT … ON CONFLICT (source_uuid) DO UPDATE` — один снапшот на агрегат [5].
- **Формат.** Сериализатор event store, по умолчанию JSON; state — `@derive Jason.Encoder`, типы
  восстанавливает `Commanded.Serialization.JsonDecoder` [1]. `source_type` — модуль struct, `metadata` —
  `%{"snapshot_module_version" => N}` [4, L38–58].
- **Инвалидация.** При чтении `metadata["snapshot_module_version"]` сравнивается с `snapshot_version` конфига
  (дефолт 1); несовпадение → `{:error, :outdated_snapshot}` → пустой struct и полная свёртка; снапшот
  перезапишется при следующем снятии [4, L21, L84–93; 3]. Гайд: при смене структуры state «**MUST** increment
  the `snapshot_version`» [1].
- **Нечитаемый снапшот.** Ошибка Postgres → `Logger.warning` и `{:error, _}` → полная свёртка [6]. Вывод из
  кода: декодирование — `Jason.decode!` и `struct(type, data)` [7], `populate` матчит только `{:ok, _}` /
  `{:error, _}` [3], исключение не перехватывается и роняет процесс в `handle_continue`; `struct/2` молча
  отбрасывает незнакомые ключи, новые поля получают дефолт.

**Тестирование.** Гайд: given — `Commanded.EventStore.append_to_stream/4` в поток агрегата (in-memory
адаптер «for test use only»), when — dispatch, then — `assert_receive_event` / `wait_for_event`, состояние —
`Aggregate.aggregate_state/3` [8]. Чистый given/when/then без store — `test/support/aggregate_case.ex` самого
репозитория: `struct() |> evolve(initial_events) |> execute(commands)` и `assert_events` / `assert_state` /
`assert_error` [9]. Файл входит в `files` hex-пакета, но в `elixirc_paths` вне `:test` / `:bench` нет [9].

## Marten

**Контракт.** Конвенциональные `Create` / `Apply` / `ShouldDelete` на самом типе («self-aggregating») или
отдельный `SingleStreamProjection<TDoc, TId>`; явный код — с Marten 8 [11; 18]. `Apply` — мутирующий `void`
или статический, возвращающий новый экземпляр [10; 11]:

```cs
public sealed record QuestParty(Guid Id, List<string> Members)
{
    public static QuestParty Create(QuestStarted started) => new(started.QuestId, []);
    public static QuestParty Apply(MembersJoined joined, QuestParty party) =>
        party with { Members = party.Members.Union(joined.Members).ToList() };
}
```

Чистота не требуется: `Create` / `ShouldDelete` принимают `IQuerySession` для чтения данных [11, conventions].
Команда — обычный handler поверх `FetchForWriting` [12].

**Пустой поток** — no-arg конструктор (может быть непубличным), `Create(event)` или конструктор от события;
на одно событие вызывается `Create` или `Apply`, не оба [11, conventions].

**Версия** — поднимает event store при append; член агрегата `Version` (int / long, по имени или `[Version]`)
Marten заполняет версией последнего применённого события [13]. Проверка — на `SaveChangesAsync`: поток
изменился после `FetchForWriting` → `ConcurrencyException` [12].

**Получение состояния.** `FetchForWriting<T>(id)` возвращает агрегат и версию потока; способ зависит от
регистрации [12]:

- `Live` (`LiveStreamAggregation<T>()` или незарегистрированный тип) — все события в память и свёртка [11; 12];
- `Inline` (`Snapshot<T>(SnapshotLifecycle.Inline)`) — загрузка сохранённого документа [12];
- `Async` — вывод из кода: join таблицы агрегата и событий `where (a.mt_version is NULL or d.version >
  a.mt_version)`, т.е. документ плюс хвост [15, L44–53]; документация: `FetchForWriting` строго согласован при
  любом lifecycle [16];
- с 9.26 — opt-in узел-локальный LRU `CacheAggregatesForWriting<T>(sizeLimit:)`: запись кэша — только baseline,
  версия и дельта событий читаются всегда, проверка конкурентности не меняется; при `Inline` запись в кэш
  только после commit, использование — только при точном совпадении версии [14];
- `UseIdentityMapForAggregates` (в Marten 9 по умолчанию `true`) делает полученный экземпляр базой
  inline-проекции; мутировать `stream.Aggregate` до `SaveChangesAsync` — «unsupported» [12].

**Снапшоты.**

- **Термин.** С Marten 8 «snapshot» — «a version of the projection», «evolve» — применение новых событий
  к нему; заявлено следование статье Chassaing [18].
- **Хранение.** Таблица документов типа агрегата с колонкой `mt_version` (вывод из кода [15]).
- **Политика.** `Inline` — в той же транзакции, что append, снапшот всегда на голове потока [14]; `Async` —
  async daemon батчами диапазонов событий [18]. Опции «каждые N событий» в документации нет; ручной пример —
  сохранять документ на бизнес-событии и дочитывать `AggregateStreamAsync(id, state:, fromVersion:)` [10].
- **Формат** — JSON-документ; поля версии схемы снапшота в документации нет.
- **Инвалидация при смене формы** — пересборка проекции daemon'ом (`RebuildProjectionAsync`, для inline и
  async) или blue/green: поднять `ProjectionVersion` (новая версия пишет в отдельные таблицы), запустить её
  `Async`, переключить трафик после догоняния [16].

**Тестирование.** Рекомендованы интеграционные тесты через Marten: `Live` — append и `AggregateStreamAsync`,
`Inline` — append и `LoadAsync` документа [17]. Given/when/then-хелпера для агрегата в документации нет.

## Emmett

**Контракт** — decider [20]:

```ts
export type Decider<State, CommandType extends Command, StreamEvent extends Event> = {
  decide: (command: CommandType, state: State) => StreamEvent | StreamEvent[];
  evolve: (currentState: State, event: StreamEvent) => State;
  initialState: () => State;
};
```

`CommandHandler({ evolve, initialState })` принимает решение как функцию `(state) => events`, которая может
вернуть Promise [21, handleCommand.ts L82–121]; `DeciderCommandHandler` принимает decider целиком и команды
[21, handleCommandWithDecider.ts L48–70]. Отказ — исключение (`IllegalStateError`, `ValidationError`),
no-op — пустой массив [19].

**Чистота** — рекомендация, типом не ограничена: «Keep the Decision Pure… on a version conflict the whole
handler re-runs» [19]. **Пустой поток** — `initialState()` [20].

**Версия** — у event store. Handler берёт `currentStreamVersion` из свёртки, в append передаёт
`expectedStreamVersion` = явная из опций ?? (`streamExists ? currentStreamVersion : STREAM_DOES_NOT_EXIST`);
append возвращает `nextExpectedStreamVersion`; конфликт — `ExpectedVersionConflictError`;
`retry: { onVersionConflict: true }` — 3 попытки, 100 мс, factor 1.5 [21, L33–39, L275–302; 19].

**Получение состояния** — полная свёртка на каждый вызов: `eventStore.aggregateStream(streamName,
{ evolve, initialState })` → решение → append [21, L182–200]. Кэша нет.

**Снапшоты** в Emmett не найдены (см. «Не найдено»). Inline-проекции PostgreSQL-адаптера пишутся в
транзакции append [24], но `CommandHandler` читает только `aggregateStream` [21].

Статья автора паттерна (Chassaing, не документация Emmett) [25]: снапшот — state плюс версия потока в
key-value хранилище; загрузка — снапшот или `(0, initialState)`, затем события после версии; инвалидация —
снапшоты одной версии кода в одной коллекции, при смене формы state менять имя коллекции,
«conceptually… a hash of the evolve function»; снапшоты можно пересчитать до деплоя.

**Тестирование.** `DeciderSpecification.for({ decide, evolve, initialState })`: given-события сворачиваются
`evolve` от `initialState()`, затем `decide` [23, L81–95]; проверки `then(events | callback)`, `thenThrows`,
`thenNothingHappened`. `then` сверяет перечисленные в ожидании поля и число событий [23, testing guide].
Уровни выше — API in-memory и e2e против PostgreSQL [23].

```ts
given([])
  .when({ type: 'AddProductItemToShoppingCart', data: { shoppingCartId, productItem }, metadata: { now } })
  .then([{ type: 'ProductItemAddedToShoppingCart', data: { shoppingCartId, productItem, addedAt: now } }]);
```

Страница `api-reference/decider` помечена «created with the help of the GenAI tool… double-checking» [22];
факты раздела взяты из исходников и how-to гайдов.

## Message DB / Eventide

Message DB — хранилище сообщений (`write_message`, `get_stream_messages`, `get_last_stream_message`,
`stream_version` и др.), функций снапшотов нет [32]. Сущность, проекция, кэш и снапшоты — библиотеки Eventide.

**Контракт.** Сущность — любой объект, «They don't have external I/O of any kind under any circumstances»
[26]. Применение событий — отдельный класс проекции, мутирующий сущность; блок `apply` не решает, применять ли
событие; событие без блока игнорируется [26]:

```ruby
class Projection
  include EntityProjection
  entity_name :account

  apply Deposited do |deposited|
    account.id = deposited.account_id
    account.deposit(deposited.amount)
  end
end
```

Команда — handler: `store.fetch(id, include: :version)` → решение по сущности →
`write.(event, stream_name, expected_version: version)` [33].

**Пустой поток** — `entity_class.build` или `.new`; `fetch` не возвращает nil, версия — `:no_stream` (= −1)
[27; 28].

**Версия** — у Message DB: `write_message` сравнивает `expected_version` со `stream_version`, при расхождении
`RAISE EXCEPTION 'Wrong expected version…'`, позиция = версия + 1 [32, L18–34]; в Ruby —
`MessageStore::ExpectedVersion::Error` [33]. Версия сущности — позиция последнего спроецированного сообщения [28].

**Получение состояния.** In-memory кэш (запись `id, entity, version, time, persisted_version, persisted_time`)
→ при промахе снапшот → события с `version + 1` → проекция → `cache.put` [27; 28, L106–165]. Кэш чистится
только рестартом процесса; scope по умолчанию `:thread`, для тестов — `:exclusive` [27].

**Снапшоты** (`EntitySnapshot::Postgres`).

- **Включение** — `snapshot EntitySnapshot::Postgres, interval: 100` в store; дефолтного интервала нет [27; 30].
- **Хранение** — поток `{entity}:snapshot-{id}` в той же Message DB, сообщение `Recorded` с данными
  `{entity_data, entity_version, time}`, пишется без `expected_version`; чтение — последнее сообщение потока
  [30; 31].
- **Политика** — вывод из кода: снапшот пишет `EntityCache#put`, вызываемый из `store.get` после дочитывания,
  если `version - persisted_version >= persist_interval` [28; 29, L79–104, L133–139], т.е. при чтении, а не при
  записи события. Документация: интервал — минимум, снапшот пишется после проецирования всех накопившихся
  событий; писать снапшоты должен только сервис-владелец, для чужих — `EntitySnapshot::Postgres::ReadOnly` [30].
- **Формат** — JSON через протокол `Transform` (`raw_data` / `instance`), реализации по умолчанию нет; ключи
  camelCase ↔ underscore_case [30].
- **Версия схемы и инвалидация.** Поля версии схемы нет [31]; снапшоты не истекают, удаляются вручную SQL [30].
- **Нечитаемый снапшот** — вывод из кода: `Transform::Read.instance` вызывается без обработки ошибок
  [31, get.rb L26–28], исключение уходит в `store.get`.

**Тестирование** — фикстуры TestBench, без given-событий: projection fixture применяет одно событие и проверяет
копирование атрибутов; handler fixture подставляет произвольные сущность и версию из store и проверяет записанное
сообщение, поток и `assert_expected_version` [34].

## Сравнительная таблица

| | Commanded | Marten | Emmett | Eventide / Message DB |
|---|---|---|---|---|
| Объявление | `execute/2` + `apply/2` у struct | `Create` / `Apply` / `ShouldDelete` или `SingleStreamProjection` | `decide` / `evolve` / `initialState` | handler + `EntityProjection` с `apply` |
| Чистота | `apply` MUST NOT fail; I/O явно не запрещён | не требуется (`IQuerySession`) | рекомендация, решение может быть async | сущность без I/O, проекция мутирует |
| Пустой поток | `struct(module)`, версия 0 | no-arg ctor / `Create(event)` | `initialState()` | `entity_class.new`, `:no_stream` |
| Версию поднимает | фреймворк (процесс) | event store; `Version` заполняется | event store | `write_message` в БД |
| Состояние для команды | процесс в памяти; снапшот на старте | Live — свёртка, Inline — документ, Async — документ + хвост; opt-in кэш | полная свёртка | кэш → снапшот → хвост |
| Хранение снапшота | `snapshots`, upsert, один на агрегат | таблица документа, `mt_version` | нет | поток `:snapshot-{id}`, append |
| Когда пишется | после команды, каждые N, вне TX | Inline — в TX append; Async — daemon | — | при чтении, ≥ N событий |
| Версия схемы | `snapshot_version` в metadata | нет; `ProjectionVersion` у проекции | — | нет |
| Смена формы | ручной bump → полная свёртка | rebuild или blue/green | — (Chassaing: новая коллекция) | не описано |
| Нечитаемый | outdated / ошибка БД → свёртка; ошибка декодирования → падение* | не описано | — | исключение наверх* |
| Тесты | через store + dispatch; `AggregateCase` в репо | интеграционные | `DeciderSpecification` | фикстуры projection / handler |

\* вывод из кода.

## Развилки

1. **Кто держит номер версии.** В агрегате (Marten заполняет `Version`) — домен видит версию, её надо
   держать в согласии с потоком. Вне агрегата (Commanded — процесс, Emmett — результат свёртки, Eventide —
   запись кэша) — агрегат версии не знает, `expected_version` передаёт инфраструктура. В `:core` сейчас версию
   поднимает домен (ADR-0001, `map.md`).
2. **Форма контракта.** Behaviour на struct (Commanded: пустое состояние — дефолты struct); значение-decider
   (Emmett: тестируется как данные, `initialState` явный); конвенции по имени (Marten: кодогенерация);
   отдельный класс проекции (Eventide: сущность не знает событий).
3. **Как команда получает состояние.** Полная свёртка (Emmett, Marten Live) — чтение всего потока на каждую
   команду, инвалидировать нечего. Долгоживущий кэш (Commanded — GenServer с подпиской; Eventide — кэш
   процесса; Marten 9.26 — LRU) — нужна память и процесс; у Marten и Eventide кэш — только baseline с
   дочитыванием хвоста. Персистентный снапшот — отдельная запись и своя инвалидация.
4. **Когда писать снапшот.** В транзакции append (Marten Inline) — снапшот всегда на голове, лишняя запись на
   каждый commit. После команды вне транзакции (Commanded) — сбой только логируется, снапшот может отставать.
   При чтении (Eventide) — пишет читающий процесс, чужим нужен ReadOnly. Фоном (Marten Async) — лаг
   компенсируется чтением хвоста. Вручную на бизнес-событии (пример Marten).
5. **Хранение.** Одна строка на агрегат с upsert (Commanded) — размер ограничен, истории нет. Append-only поток
   (Eventide) — растёт, очистка вручную. Таблица документов типа (Marten) — снапшот совпадает с read-моделью.
6. **Инвалидация при смене формы.** Номер в metadata, сравниваемый при чтении (Commanded) — дёшево, bump
   ручной и обязателен. Новая коллекция / хеш `evolve` (Chassaing) — автоматически, старые данные живут до
   удаления. Пересборка / blue-green по `ProjectionVersion` (Marten) — daemon и параллельные таблицы.
7. **Нечитаемый снапшот.** Считать отсутствующим и сворачивать с нуля (Commanded для `outdated_snapshot` и
   ошибки БД) или падать (Commanded при ошибке декодирования, Eventide — вывод из кода). Явного fallback на
   ошибку десериализации ни один источник не описывает.
8. **Тесты.** Given-события / when-команда / then-события без БД (Emmett, `AggregateCase` Commanded); через
   store и dispatch (гайд Commanded, Marten); фикстуры с подставленными сущностью и версией (Eventide).

## Не найдено

- **Emmett:** снапшоты или кэш состояния для `CommandHandler` — нет в документации, в исходниках пакета
  `emmett` (grep находит только `pg_snapshot_xmin` и файлы миграций) и в issues (поиск «snapshot»: #21 —
  snapshot-тесты схем событий, #172 — chunking потоков MongoDB).
- **Marten:** поведение при недесериализуемом документе снапшота; политика «каждые N событий»; поле версии
  схемы внутри документа.
- **Commanded:** документированное поведение при повреждённом снапшоте — есть только код.
- **Eventide:** версионирование формата снапшота, инвалидация при смене формы сущности, обработка нечитаемого
  снапшота в документации.
- **Message DB:** собственных функций снапшотов нет — их даёт библиотека Eventide.
- **Нагрузка:** данных для выбора N не приводит ни один источник; Eventide: интервала по умолчанию нет,
  настраивается под сервис [30].

## Источники

1. Commanded, `guides/Aggregates.md` @ `936dbb1` —
   https://github.com/commanded/commanded/blob/936dbb166af0e348bf3317c4714590112336b827/guides/Aggregates.md ;
   https://commanded.hexdocs.pm/aggregates.html
2. Commanded, `lib/commanded/aggregates/aggregate.ex` @ `936dbb1` —
   https://github.com/commanded/commanded/blob/936dbb166af0e348bf3317c4714590112336b827/lib/commanded/aggregates/aggregate.ex
3. Commanded, `lib/commanded/aggregates/aggregate_state_builder.ex` @ `936dbb1` —
   https://github.com/commanded/commanded/blob/936dbb166af0e348bf3317c4714590112336b827/lib/commanded/aggregates/aggregate_state_builder.ex
4. Commanded, `lib/commanded/snapshotting.ex` @ `936dbb1` —
   https://github.com/commanded/commanded/blob/936dbb166af0e348bf3317c4714590112336b827/lib/commanded/snapshotting.ex
5. EventStore, `lib/event_store/sql/init.ex` и `lib/event_store/sql/statements/insert_snapshot.sql.eex` @ `930f921` —
   https://github.com/commanded/eventstore/blob/930f9214cf8ed47e8342e73c9fb364d975140770/lib/event_store/sql/init.ex
6. EventStore, `lib/event_store/storage/snapshot.ex` @ `930f921` —
   https://github.com/commanded/eventstore/blob/930f9214cf8ed47e8342e73c9fb364d975140770/lib/event_store/storage/snapshot.ex
7. Commanded, `lib/commanded/serialization/json_serializer.ex` @ `936dbb1` —
   https://github.com/commanded/commanded/blob/936dbb166af0e348bf3317c4714590112336b827/lib/commanded/serialization/json_serializer.ex
8. Commanded, `guides/Testing.md` @ `936dbb1` —
   https://github.com/commanded/commanded/blob/936dbb166af0e348bf3317c4714590112336b827/guides/Testing.md ;
   https://commanded.hexdocs.pm/testing.html
9. Commanded, `test/support/aggregate_case.ex`, `mix.exs` @ `936dbb1` —
   https://github.com/commanded/commanded/blob/936dbb166af0e348bf3317c4714590112336b827/test/support/aggregate_case.ex
10. Marten, Live Aggregation (`docs/events/projections/live-aggregates.md` @ `3e56e4f`) —
    https://martendb.io/events/projections/live-aggregates.html
11. Marten, Single Stream Projections and Snapshots; Conventions —
    https://martendb.io/events/projections/single-stream-projections.html ;
    https://martendb.io/events/projections/conventions.html
12. Marten, CQRS Command Handler Workflow (`docs/scenarios/command_handler_workflow.md`) —
    https://martendb.io/scenarios/command_handler_workflow.html
13. Marten, Using Metadata — https://martendb.io/events/projections/using-metadata.html
14. Marten, Optimizing Performance («Caching Aggregate Snapshots for FetchForWriting») —
    https://martendb.io/events/optimizing.html
15. Marten, `src/Marten/Events/Fetching/FetchAsyncPlan.cs` @ `3e56e4f` —
    https://github.com/JasperFx/marten/blob/3e56e4f68999e0b2c1ad379901bfa278e8575f93/src/Marten/Events/Fetching/FetchAsyncPlan.cs
16. Marten, Rebuilding Projections — https://martendb.io/events/projections/rebuilding.html
17. Marten, Testing Projections — https://martendb.io/events/projections/testing.html
18. Marten, Aggregate Projections — https://martendb.io/events/projections/aggregate-projections.html
19. Emmett, Command Handling (`src/docs/guides/command-handling.md` @ `d1882f6`) —
    https://event-driven-io.github.io/emmett/guides/command-handling.html
20. Emmett, `src/packages/emmett/src/typing/decider.ts` @ `d1882f6` —
    https://github.com/event-driven-io/emmett/blob/d1882f692014366b7fef28f0e1cec925590dd697/src/packages/emmett/src/typing/decider.ts
21. Emmett, `src/packages/emmett/src/commandHandling/handleCommand.ts`, `handleCommandWithDecider.ts` @ `d1882f6` —
    https://github.com/event-driven-io/emmett/blob/d1882f692014366b7fef28f0e1cec925590dd697/src/packages/emmett/src/commandHandling/handleCommand.ts
22. Emmett, Decider (API reference, помечена как GenAI-черновик) —
    https://event-driven-io.github.io/emmett/api-reference/decider.html
23. Emmett, `src/packages/emmett/src/testing/deciderSpecification.ts` @ `d1882f6`; Testing guide; сниппет
    `src/docs/snippets/gettingStarted/businessLogic.unit.spec.ts` —
    https://github.com/event-driven-io/emmett/blob/d1882f692014366b7fef28f0e1cec925590dd697/src/packages/emmett/src/testing/deciderSpecification.ts ;
    https://event-driven-io.github.io/emmett/guides/testing.html
24. Emmett, PostgreSQL event store (`src/docs/event-stores/postgresql.md`) —
    https://event-driven-io.github.io/emmett/event-stores/postgresql.html
25. Jérémie Chassaing, «Functional Event Sourcing Decider», 2021-12-17 (статья автора паттерна) —
    https://thinkbeforecoding.com/post/2021/12/17/functional-event-sourcing-decider
26. Eventide docs, `user-guide/entities.md`, `user-guide/projection.md` @ `913c3ce` —
    https://github.com/eventide-project/docs/blob/913c3cecd294d9a416ca2be0759a4d7a14ee4c19/user-guide/projection.md
    (сайт: https://docs.eventide-project.org/)
27. Eventide docs, `user-guide/entity-store/README.md`, `entity-cache.md` @ `913c3ce` —
    https://github.com/eventide-project/docs/blob/913c3cecd294d9a416ca2be0759a4d7a14ee4c19/user-guide/entity-store/README.md
28. entity-store, `lib/entity_store/entity_store.rb` @ `f551413` —
    https://github.com/eventide-project/entity-store/blob/f551413c4689a5bfe6b5c3902b9f157e85d20567/lib/entity_store/entity_store.rb
29. entity-cache, `lib/entity_cache/entity_cache.rb` @ `e9e068e` —
    https://github.com/eventide-project/entity-cache/blob/e9e068e4118a2ff80785ebfef7256af7b28b5ce5/lib/entity_cache/entity_cache.rb
30. Eventide docs, `user-guide/entity-store/snapshotting.md` @ `913c3ce` —
    https://github.com/eventide-project/docs/blob/913c3cecd294d9a416ca2be0759a4d7a14ee4c19/user-guide/entity-store/snapshotting.md
31. entity-snapshot-postgres, `lib/entity_snapshot/postgres/postgres.rb`, `get.rb` @ `b903b65` —
    https://github.com/eventide-project/entity-snapshot-postgres/blob/b903b65dc30d052ed539ee483d949e2a4bab94bb/lib/entity_snapshot/postgres/get.rb
32. message-db, `database/functions/write-message.sql` и каталог `database/functions` @ `25da82b` —
    https://github.com/message-db/message-db/blob/25da82b044f94416202ac3daa1866791b385badc/database/functions/write-message.sql
33. Eventide docs, `user-guide/message-handlers.md`, `user-guide/writing/expected-version.md` @ `913c3ce` —
    https://github.com/eventide-project/docs/blob/913c3cecd294d9a416ca2be0759a4d7a14ee4c19/user-guide/writing/expected-version.md
34. Eventide docs, `user-guide/test-fixtures/projection-fixture.md`, `handler-fixture.md` @ `913c3ce` —
    https://github.com/eventide-project/docs/blob/913c3cecd294d9a416ca2be0759a4d7a14ee4c19/user-guide/test-fixtures/handler-fixture.md
