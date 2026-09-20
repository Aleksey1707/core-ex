# События и Outbox

- **Область.** `lib/core/es/**`, `lib/core/outbox/**`, `lib/core/pubsub/**`; у потребителя —
  `<Aggregate>.Event`, `<Aggregate>.Outbox`, подписчики и воркеры.
- **Читать перед.** Новым событием или правкой его wire-формата, изменением outbox (поллер,
  delivery, cleaner), разбором записей в `:failed` и сообщений в DLQ.
- **Словарь.** Плейсхолдеры и модальность — `00-index.md`.

## Domain events

Событие агрегата: `use Es.Event` (см. `11-domain.md`) + вложенный `Payload` (или `nil`).

Dump/load события — только через фасад (`11-domain.md`, «Dump/load только через фасад»).
Неизвестный тег → `:unknown_event_type` (`ns: :es`): ошибку строит кодек агрегата, clause с этим
кодом в каталоге `<Aggregate>.Errors` MUST NOT. Момент постановки в outbox:
`Outbox.CreatedAt.now()` (usec); `event.at` — только в конверте (`"at"`), не в
`Record.created_at`.

Правила:

- Агрегат при мутациях **копит** `events` в struct; сам не пишет в event store и outbox.
- Flush — задача Repo, **в одной DB-транзакции** со state.
- Flush руками не пишется: его генерирует `use Core.Repo.Pg.StateStored` по опциям `event_codec:`
  и `outbox:` (см. `13-repos.md`). Порядок внутри транзакции:
  `Outbox.from_events` → `Core.Es.Store.append` → `Outbox.Repo.append`, затем `events` очищаются.
- Кодек событий агрегата — `use Core.Es.Event.Codec` (`event:` + `type:` + `tags:`, необязательный
  `upcasts:`; колбэки `dump_payload/2`, `load_payload/3`, `upcast/2`); конверт, выбор типа по тегу
  и сборку события генерирует билдер, наружу кодек виден только через фасад.
  `load_payload/3` возвращает `%Payload{}` своего события, а не событие; событиям без нагрузки
  клоузы не нужны вовсе. Проверяется: предупреждение на строке `use Core.Es.Event.Codec` — у
  события с нагрузкой нет clause `dump_payload/2` или `load_payload/3`, `load_payload/3` отдаёт
  нагрузку другого события литералом или через `Payload.new` (`make consumer-check`).
- Prim агрегата и автора билдер выводит из самих событий (`__es_aggregate_id__/0`,
  `__es_by__/0`) — опциями они не задаются, расхождение между событиями одного кодека
  ловится на компиляции.
- `type:` у кодека событий — MUST: тип агрегата в формате тега. Проверяется на компиляции:
  кодек без `type:` и один `type:` у двух кодеков среди плагинов фасада — `CompileError`.
- Wire-тег уникален **внутри своего кодека**: дубль — `CompileError`. Квалификация тега именем
  агрегата и уникальность между агрегатами — `deps/core/docs/rules/app/14-events-outbox.md`,
  «Wire-тег события».
- Кодек событий MUST быть в `Codec.plugins()` — иначе фасад не знает ни события, ни его
  семейства.

Источники `:version_mismatch` из `<Aggregate>.Errors` у state-stored агрегата:

- `get` / `update` — версия строки не совпала с версией клиента или эталоном `Repo.Sc`;
- `Core.Es.Store.append` — версия потока занята конкурентной записью (unique
  `(aggregate_type, aggregate_id, aggregate_version)`) либо в потоке есть событие более поздней
  транзакции (страж `xid`); detail — `%{aggregate_id, expected, actual, source: :storage}`, модуль
  ошибки — `behaviour:` write-репозитория.

Отказ стража бывает ложным — транзакция получила `xid` раньше, чем закоммитился конкурент по тому
же потоку (`docs/adr/0008-shared-event-table-xid8-position.md`), — и отдельного кода у него нет:
и он, и занятая версия — отказ хранилища, `source: :storage`. Usecase MAY повторить команду
state-stored агрегата целиком — тем же `Core.Es.Transact.run/2` (`13-repos.md`, «Транзакция
команды (`Core.Es.Transact`)»): `get` заново сверит версию клиента. На строке агрегата
`optimistic_lock` не используется — `version` проверяется на чтении, а расходится он именно на
записи событий.

## Aggregate → Outbox.Record

Модуль `<Aggregate>.Outbox` целиком генерируется — руками только `@moduledoc` и две опции:

```elixir
use Es.Outbox,
  topic: "<topic>",
  event: Agg.Event
```

`topic` валидируется `Outbox.Topic` на этапе компиляции: опечатка — `CompileError`, а не ошибка
в рантайме на каждом событии.

Агрегат, чьи события наружу не публикуются, модуля `<Aggregate>.Outbox` не заводит: его
write-репозиторий объявляет `outbox: :none` (`13-repos.md`).

API:

- `from_event/1` → `{:ok, Record.t()} | {:error, Error.t()}`
- `from_events/1` → `{:ok, [Record.t()]} | {:error, Error.t()}`

Поля Record: topic / key (= aggregate id) / name (= event name) / payload (JSON-объект) / headers
(MQ-заголовки | `nil`) / lifecycle-поля (`status`, `attempts`, `locked_until`, `lease_id`, …).

`payload` — **только map**: колонка `payload` имеет тип `:map`, и list / binary / скаляр не дампятся
(падение на записи). Нужен не-JSON body — это отдельная колонка и отдельное решение, а не расширение
типа.

`Delivery.Mq`: body = `Jason.encode(payload)`. Headers — `Record.headers` как есть (`nil` → без
заголовков); delivery MUST NOT достраивать **прикладные** заголовки из `name` / `key` / payload.

Во что `Mq.Message` превращается на проводе, задаёт адаптер `Mq.Writer`, а не delivery —
`10-architecture.md`, «Wire-формат принадлежит адаптеру».

Заголовки задаёт продюсер записи. Для событий агрегата — `<Aggregate>.Outbox.from_event/1`: `name`
(= event name), `aggr_id` (= aggregate id), `event_id`.

Единственное исключение — **транспортный** `traceparent` (`Core.Otel.Messaging`):
он не несёт предметного смысла и обязан описывать то звено, в котором сообщение
реально появилось на проводе, а не то, что записало строку. Его ставит `Delivery.Mq`
при публикации, и он единственный заголовок, который delivery добавляет от себя;
`Delivery.to_message/1` при этом остаётся чистым преобразованием и заголовков
не трогает.

Wire-payload — конверт события целиком:

- `event_id`, `type`, `aggregate_id`, `aggregate_version`, `at`, `by`
- плюс payload события (`payload`; у событий без нагрузки — `nil`)

Обе стороны формата — в `Core.Es.Event.Codec`: конверт собирает `dump/2` кодека агрегата
(его зовёт `<Aggregate>.Outbox` при постановке события в очередь), разбирает — `load/3`,
до которого подписчика доводит фасад по тегу. Разносить стороны формата по разным модулям
MUST NOT: переименованный ключ обнаружится не тестом, а подписчиком в проде. Транспорту,
который хранит поля врозь (event store — по колонкам), их отдаёт пара `to_fields/1` /
`from_fields/1`: строковые ключи конверта не покидают кодека.

Разбор **safe**: событие с типом, которого кодек больше не знает, становится доменной
ошибкой у подписчика (`:unknown_event_type`), а отсутствующее обязательное поле конверта —
`:invalid_envelope` (обе — `ns: :es`); сообщение из брокера переживает код, который его
писал, и уронить подписчика не вправе.

## Совместимость событий

Строки в event store живут вечно и читаются текущим кодом. Единственный источник wire-имён —
`@tag_by_mod` в `<Aggregate>.Event.Codec`; формат payload задаёт `dump_payload/2`.
Оттуда же его берут запись outbox и её заголовки (`Core.Es.Event.Codec.to_fields/1`).
Любое несовместимое изменение обнаружится не в тесте, а на проде — при чтении истории.

Версия схемы события — его тег; записанное событие старого тега приводится к текущей схеме
апкастом в кодеке агрегата при чтении (ADR-0010).

| Изменение | Статус |
|---|---|
| новое событие (новый тег) | разрешено |
| новое **опциональное** поле нагрузки | разрешено, тег прежний; `load_payload` читает нагрузку без него |
| новое обязательное поле, переименование или удаление поля, смена типа значения | новый тег + апкаст со старого |
| переименование тега | новый тег + апкаст со старого, нагрузка как есть |
| удаление типа события | тег остаётся в `tags:`, писать перестают |
| ужесточение проверок Prim в нагрузке или заголовке | MUST NOT; новый Prim + новый тег |
| ослабление проверок Prim | разрешено |
| изменение записанных строк хранилища событий | MUST NOT; инструмента переписывания нет |

- Тег остаётся в кодеке навсегда — в `tags:` или источником в `upcasts:`.
- Апкаст — `upcasts: %{"старый тег" => "новый тег"}` у `use Core.Es.Event.Codec` и колбэк
  `upcast(old_tag, envelope)`, отдающий нагрузку следующего тега. Цепочка идёт по шагам
  (v1 → v2 → v3), заголовок конверта колбэк только читает, ошибку формы нагрузки ловит
  `load_payload/3`. Срабатывает только при загрузке по семейству
  (`InCodec.load(<Aggregate>.Event, _)`): `InCodec.load(Mod, _)` тег не читает и не апкастит.

Проверяется: `CompileError` в `use Core.Es.Event.Codec` — источник в `tags:`, цель ни в `tags:`,
ни источником, цикл в карте, непустые `upcasts:` без `upcast/2`.

```elixir
# плохо — старый тег удалён из кодека: записанные события перестают читаться
@tag_by_mod %{Event.Registered => "delivery.registered.v2"}

# плохо — история переписана миграцией вместо апкаста
execute("UPDATE delivery_events SET type = 'delivery.registered.v2' WHERE type = 'delivery.registered'")

# плохо — у Prim нагрузки `max_len: 255` → `100`: записанные длинные адреса перестают грузиться
use Core.Prim.String,
  name: "Адрес",
  max_len: 100

# хорошо — новый тег, старый — источник апкаста
@tag_by_mod %{Event.Registered => "delivery.registered.v2"}
@upcasts %{"delivery.registered" => "delivery.registered.v2"}

use Es.Event.Codec,
  event: Event,
  type: "delivery",
  tags: @tag_by_mod,
  upcasts: @upcasts

@impl true
def upcast("delivery.registered", envelope) do
  payload = field(envelope, :payload)
  %{"address" => %{"line" => field(payload, :address)}}
end
```

### Golden-фикстуры

`test/support/fixtures/events/<тип агрегата>/<тег>.json` — снимок дампа каждого события.
Файлы **не перегенерируются**: это то, что уже лежит в проде.

Тест на агрегат (`use Core.Es.EventCompatCase`, `19-testing.md`) проверяет четыре инварианта:

1. у каждого тега из `Event.Codec.types/0` есть фикстура — новый тип не добавить,
   не зафиксировав формат;
2. каждая фикстура, кроме источников `upcasts:`, несёт в `type` тег из имени файла и грузится
   через `InCodec.load(<Aggregate>.Event, _)` — переименование тега или поля, удаление поля,
   смена типа значения и тег, удалённый из кодека, ломают тест;
3. у каждого источника `upcasts:` есть фикстура — записанный старый формат зафиксирован;
4. фикстура источника несёт его тег и грузится — апкаст доводит старый формат до текущей схемы.

Полноту `evolve` проверяет сборка репозитория агрегата (`11-domain.md`, «Event-sourced»).
Фикстуры текущих тегов гоняет и `use Core.Es.ProjectionCase` — очистку `clear/0` проекции
(`19-testing.md`, «Проекции»).

Добавили событие — добавьте фикстуру (дамп реального события, не выдуманный JSON).
Понадобилось несовместимое изменение — это новый тег и апкаст со старого, а не правка фикстуры:
фикстура старого тега остаётся под прежним именем и становится фикстурой источника.

## Outbox lifecycle

Статусы: `:new → :in_work → :published | :failed`.

| Компонент | Назначение |
|---|---|
| `Poller` | reserve (под токеном аренды `lease_id`) → `publish_many` → save_results; один sequential publisher; drain после `:processed`; `:retry` / idle / error — adaptive backoff; `wake/1` после commit `append` (`nil` и отсутствующий процесс → `:ok`; coalesce `:wake` в mailbox) |
| `Delivery.Mq` | JSON body + `Record.headers` как есть; `publish_many` → `Writer.put_many` (stop-on-first-error). Единственный Delivery: брокер подключается адаптером `Mq.Writer` (`Mq.Stream.Writer`, `Mq.Kafka.Writer`), не отдельным `Delivery.*`. Модуль реализации поллер берёт из опции `:delivery_module`; выводить его из `__struct__` handle MUST NOT — `Delivery.t()` структуры не требует |
| `Cleaner` | TTL published |

Поддерево очереди (`Writer` → `Poller` → `Cleaner`) собирает супервизор приложения; своего
супервизора у библиотеки нет.

Ключ конфига — `Core.Outbox` (Core-namespace, не app-модуль `MyApp.Outbox`). Библиотека читает из
него только цели пробуждения после commit `append` (`Outbox.Repo.Pg`):

- `poller_name` — atom имени GenServer; `nil` — wake no-op;
- `pollers` — `[[name:, topics:], …]`: будится каждый поллер, чей фильтр топиков совпал с пачкой.

Остальное — опции `Poller` / `Cleaner` (обязательные и дефолты — их moduledoc), их передаёт
супервизор приложения. Где лежат значения, из каких env приходят и как задаются длительности —
`deps/core/docs/rules/app/14-events-outbox.md`, «Конфигурация».

### Poller scheduling

Исход цикла — `:processed` (вся пачка опубликована) / `:retry` (хоть одна запись пачки
не опубликована) / `:idle` / `{:error, _}`.

- После `:processed` — немедленный следующий цикл (`schedule(0)`, drain очереди).
- После `:retry` — backoff **всегда**, в том числе при пришедшем во время цикла `:wake`:
  новые записи не делают публикуемой ту голову очереди, на которой цикл споткнулся.
- После `:idle` / ошибки цикла — backoff: `idle_min_ms`, ×2, …, cap = `poll_interval_ms`.
- Если во время цикла пришли `:wake` и результат `:idle` / error — `schedule(0)` (не полный
  backoff).
- Сброс backoff'а MUST делать `reschedule_after/2` по исходу цикла, а не `handle_info(:wake, …)`
  заранее: иначе непрерывный `append` при лежащем брокере держит интервал на минимуме.
- Входящие `:wake` coalesce'ятся (`flush_wakes` в начале/конце цикла) — mailbox не растёт
  пропорционально RPS `append`.
- `Outbox.Repo.append` регистрирует через `Helper.AfterCommit` вызов `Poller.wake/1` для целей из
  `poller_name` / `pollers` (после outermost commit; вне TX — сразу). Same-VM only; другие
  ноды — safety poll.
- `DAO` объявляется через `use Core.DAO`: `transact` / `transaction` обёрнуты в `AfterCommit.wrap`
  (depth / rollback-safe).

`retry` и `failed` в исходе цикла считаются по **записям пачки**, а не по повторам доставки:
при fail-stop в `:new` возвращается и сбойная запись, и весь хвост после неё. Читать как
«не опубликовано в этом цикле». Те же измерения уходят в метрику (README, «Имена метрик»).

`Delivery.publish_many/2` MUST возвращать индекс **внутри** пачки; индекс за границей поллер
трактует как провал с нулевого и пишет `error` с `index=` и `size=`. Досчитать такую пачку
до конца нельзя: записи ушли бы в `published`, не побывав в брокере.

Окно до `:failed` — это `max_attempts` × backoff; оно MUST превышать время рестарта брокера
и задаётся тройкой опций `idle_min_ms` / `poll_interval_ms` / `max_attempts`.

Почему backoff общий для очереди, а не отложенный retry на запись, и таблица окон —
ADR-0002.

### Порядок доставки

- Один Poller + один `Stream.Writer`; concurrency > 1 запрещён (порядок в stream).
- Порядок publish = `order_by: created_at` при `fetch_and_reserve`.
- Ошибка на index `i` в батче — fail-stop: `0..i-1` published, `i` failure/retry, `i+1..` →
  `Record.release` (`:new`, без инкремента attempts).
- `Mq.Writer.put_many/2` / `Delivery.publish_many/2` — sequential publish в одном call.

`Outbox.Repo` API: `append`, `fetch_and_reserve`, `save_results`, `release`,
`delete_published_before` (возвращает `non_neg_integer()` — число удалённых), `requeue_failed`,
статистика для метрик (`queue_counts`, `oldest_age_seconds`, `expired_lock_count`).

`Cleaner` удаляет только `published`: записи `:failed` остаются до разбора оператором.
`requeue_failed/2` (его зовёт `mix outbox.requeue --all` / `--id <uuid>`) переводит `:failed` →
`:new`, обнуляет `attempts`, снимает аренду и очищает `errors` — счётчик попыток стартует с нуля,
и сохранённая история пронумеровалась бы заново поверх старой. Порядок доставки для возвращённых
записей не восстанавливается: сообщения, шедшие за ними, уже опубликованы. Разбор записей в
`:failed` — `deps/core/docs/rules/app/14-events-outbox.md`, «Runbook: записи в `:failed`».

### Запросы очереди — только по индексу

- `fetch_and_reserve` MUST брать кандидатов **двумя** индексными запросами (`:new` и
  просроченные `:in_work`) со своим `LIMIT` у каждого и сливать результаты. Один запрос
  с `OR` MUST NOT: `LIMIT` применяется после сортировки всего подходящего множества.
- Порядок при слиянии MUST задавать `DateTime.compare/2`. Термовое сравнение `%DateTime{}`
  идёт по ключам структуры (`:day` раньше `:month`) — 1 февраля оказалось бы «раньше»
  31 января. Tiebreaker — `id`.
- `queue_counts/0` MUST считать только `:new` / `:in_work` / `:failed` — статусы, ограниченные
  по природе и покрытые частичными индексами. `:published` MUST NOT: он растёт неограниченно,
  и точный счёт по нему стоит скана всей таблицы на каждый опрос метрик.
- Новый запрос к `outbox`, идущий по таймеру или в цикле поллера, MUST ложиться на частичный
  индекс. Проверять `EXPLAIN (ANALYZE, BUFFERS)` на объёме, а не на пустой таблице: планы
  расходятся на три порядка только под данными.

Состав индексов — часть контракта таблицы: DDL лежит в `Core.Outbox.Migration`, миграция
потребителя делегирует ему (`deps/core/docs/rules/app/18-migrations.md`, «Таблицы библиотеки»).
Имена индексов контрактом не являются. Схема `outbox` меняется только аддитивно — новая
nullable-колонка, новый индекс `concurrently`; переименование и удаление колонок MUST NOT:
очередь несёт историческую нагрузку, а изменение DDL доходит до потребителя его собственной
миграцией по пункту `CHANGELOG.md`.

Почему так и чем платим — ADR-0003 (выборка пачки) и ADR-0005 (метрики очереди).

**Fencing аренды.** `fetch_and_reserve` выдаёт пачке общий `lease_id` и пишет его в строку;
`save_results` / `release` обновляют строки `UPDATE ... WHERE id IN (...) AND lease_id = ?`.
Перехваченная после истечения аренды запись и удалённая `Cleaner` строка не обновляются и
не воскресают (upsert здесь запрещён) — расхождение уходит в `warning`.

**Порядок внутри пачки** — `order_by: [created_at, id]`: `created_at` ставится на каждое событие
отдельно и может совпасть в микросекунде, `id` (UUIDv7) даёт tiebreaker. Часть ошибок — `Error.app`
+ `raise Exc`. Persist `Record` в Schema — через `Outbox.Codec` / `InCodec.load`/`dump` (remap JSON
errors string↔atom keys). `append` чанкует `insert_all` (лимит параметров PostgreSQL при
больших batch).

### Единственность поллера

Гарантия порядка держится на одном поллере на топик-группу; как приложение обеспечивает это на
нодах и на старте — `deps/core/docs/rules/app/14-events-outbox.md`, «Единственность поллера».

`Core.Outbox.check_singleton!/1` отказывает `ArgumentError` с инструкцией, если включённый outbox
(`enabled?:`) стартует при заданной кластеризации (`cluster_query:`); с `allow_cluster?: true`
пропускает старт и пишет `warning`. `cluster_query` `nil`, `:ignore` и `""` — кластеризации нет.
Значения передаются опциями, а не читаются из конфигурации: ключ кластеризации принадлежит
приложению (`10-architecture.md`).

`Core.Outbox.validate_partition!/1` принимает конфиг `pollers` как есть и отказывает
`ArgumentError`, если фильтры топиков двух поллеров пересекаются; раскладка на один поллер
проверки не требует. Что считается пересечением — `@doc` у `Outbox.topics_overlap?/2`: два
`{:except, _}` пересекаются всегда.

Проверяется: `test/core/outbox/singleton_test.exs`, `test/core/outbox/partition_test.exs`.

## Трассировка цепочки

Контекст OTel живёт в process dictionary: между записью строки и её публикацией —
цикл поллера в другом процессе, между публикацией и обработкой — брокер. Ни то, ни
другое контекст не переживает, поэтому он переносится заголовками (`Core.Otel`).

Имена и структура — по semantic conventions messaging (`Core.Otel.Messaging`):

| Звено | Span | Связь |
|---|---|---|
| `<Aggregate>.Outbox.from_event/1` | нет; `traceparent` изменяющего usecase кладётся в `Record.headers` | — |
| `Delivery`, на сообщение | `"create <topic>"`, `kind: :producer` | родитель — `traceparent` из `Record.headers` |
| `Delivery`, на пачку | `"send <topic>"` (или `"send"`), `kind: :producer` | `links` на create-спаны пачки |
| `MqSubscriberReliable` | `"process <topic>"`, `kind: :consumer` | родитель — `traceparent` из заголовков сообщения |

Send и create связаны **ссылками**, а не вложенностью: сообщения одной пачки приходят
из разных трейсов, и создание сообщения не происходит внутри его отправки. Спека
требует того же: «The 'Send' span SHOULD always link to the creation context that was
injected into a message».

Родитель обработчика — create-span своего сообщения, а не пачка: иначе трейс изменяющего
usecase обрывался бы на поллере, а сообщения одной пачки склеились бы в один трейс.

Имя span'а — `{операция} {назначение}`; у пачки из разных топиков назначения нет,
и остаётся `"send"`: топик в имени сделал бы его высококардинальным.

Span вокруг `Poller` MUST NOT: цикл поллера — периодический опрос БД, и его span
на каждом тике — шум, а не трейс. Работу покрывает батч-span в delivery.

## Идемпотентность потребителей

Доставка — **at-least-once** на каждом звене: outbox переотправляет батч после сбоя,
брокер передоставляет неподтверждённое. Значит, обработчик обязан переживать повтор. Как
приложение делает свои обработчики и фоновые задачи идемпотентными —
`deps/core/docs/rules/app/14-events-outbox.md`, «Идемпотентность потребителей».

- Проекция и реакция на событие с внешним эффектом — `22-projections.md`, «Read-модель».
- Исход обработчика `MqSubscriberReliable` (`PubSub.handler_result()`): `:ok` и
  `{:skip, reason}` коммитят offset; `{:error, _}`, ошибка `from_message` и исключение в
  обработчике — нет, сообщение приходит снова с растущим интервалом. Исключение не роняет
  подписчик: оно становится `{:error, _}` (`:handler_crashed`).
- «Ядовитое» сообщение (обработчик стабильно возвращает ошибку) MUST иметь выход:
  `MqSubscriberReliable` считает попытки, растит интервал до `retry_max_ms` и после
  `max_attempts` публикует сырое сообщение в DLQ-топик (`<topic>.dlq`, заголовки
  `x-dlq-source-topic` / `x-dlq-attempts` / `x-dlq-error`), коммитит offset и эмитит
  `[:mq, :subscriber, :dlq]` (алерт `MqSubscriberDlq` — `21-observability.md`, «Рекомендованные
  алерты»). Без настроенного `dlq_writer` сообщение не выбрасывается — повторы продолжаются, в
  лог идёт `error`.
- DLQ-writer подписчику передаётся опциями `dlq_writer` (модуль `Mq.Writer`) и `dlq_handle` (его
  handle) — только парой, одна без другой роняет старт `ArgumentError`; чей это writer и где он
  стоит в дереве — `deps/core/docs/rules/app/14-events-outbox.md`, «Подписчики». Проверяется:
  `test/core/pubsub/mq_subscriber_reliable_test.exs`, describe «опции старта».

### Runbook: сообщения в DLQ

1. Алерт `MqSubscriberDlq` → топик и `dlq_topic` в метках.
2. Причина — в логе подписчика (`сообщение отправлено в DLQ после N попыток`) и в заголовке
   `x-dlq-error` самого сообщения.
3. Починить обработчик, затем переиграть содержимое DLQ-стрима в исходный топик
   (порядок относительно уже обработанных сообщений не восстанавливается).

## Связанные правила

- Es.Event / агрегаты / `Event.Codec` — `11-domain.md`
- OTP-процессы поллеров и читателей — `17-otp-concurrency.md`
- Flush в Repo (`Repo.Pg.StateStored`), хранилище событий (`Core.Es.Store`) — `13-repos.md`
- Кеш ReadRepo (инвалидация по событиям) — `deps/core/docs/rules/app/16-caching.md`
- Конфигурация, единственность поллера, runbook и идемпотентность приложения —
  `deps/core/docs/rules/app/14-events-outbox.md`
- Рекомендованные алерты очереди и подписчиков — `21-observability.md`
- Архитектура слоёв — `10-architecture.md`
