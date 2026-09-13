# Эволюция событий и апкастинг: Commanded + EventStore, Marten, Emmett, Message DB, Greg Young

Исследование на 2026-09-13. Код читался на тегах: commanded `v1.4.11` (`91d97bc`), eventstore `v1.4.8`
(`0bf4f2e`), commanded-eventstore-adapter `v.1.4.2` (`7f34860`), marten `V9.33.0` (`eb6263d`), emmett `0.42.4`
(`dc0b5ac`), message-db `v1.3.0` (`e6999a6`), eventide-project/docs `913c3ce`, eventide-project/messaging `82ae099`.
Цитаты оставлены на языке оригинала. «Вывод» — заключение из прочитанного кода, прямо в источнике не сказано.

## Вопрос

[Тикет](../issues/03-research-upcasting.md): где выполняется апкаст и что он получает на вход; как определяется
версия схемы; переименование и удаление типа, неизвестный тип при восстановлении агрегата и в проекции; апкаст
на лету против copy-transform; влияние на снапшоты и проекции.

## Commanded + EventStore

**Место и вход.** Протокол `Commanded.Event.Upcaster`, `upcast(event :: struct(), metadata :: map()) :: struct()`;
реализация `Any` возвращает событие без изменений [1]. Вызывает его `Commanded.Event.Upcast.upcast_event/2`
над полем `data` у `%RecordedEvent{}` [2], то есть уже **после** десериализации. Места вызова:
`Commanded.EventStore.stream_forward/4` (через него агрегат восстанавливается) [3], подписка агрегата
на свой поток, `Event.Handler` («Upcast events once before any processing») и `ProcessRouter` [4].
Метаданные с atom-ключами: `event_id`, `event_number`, `stream_id`, `stream_version`, `causation_id`,
`correlation_id`, `created_at` [1]. Докстринг: «Upcaster will run for new events and for historical events…
consumers… only need to support the latest version» [1].

**Десериализация до апкаста.** EventStore вызывает `serializer.deserialize(data, type: event_type)`
в `RecordedEvent.deserialize/2` [5]. `Commanded.Serialization.JsonSerializer` превращает тип в struct через
`TypeProvider.to_struct/1` [6]. По умолчанию это `ModuleNameTypeProvider`: тип `"Elixir.An.Event"`,
`String.to_existing_atom() |> struct()` [6]. Провайдер можно заменить через `config :commanded, :type_provider` [6].

**Версия схемы.** Отдельного поля нет. Тип — имя модуля, протокол выбирает реализацию по struct.

**Переименование типа.** Гайд показывает замену исторического события новым: `%HistoricalEvent{}` → `%NewEvent{}` [7].
Вывод: старый модуль нужен навсегда, иначе нет ни `to_existing_atom`, ни диспетчеризации протокола [1][6].
Альтернатива — свой `TypeProvider`, но есть только behaviour, примера в гайдах нет.

**Неизвестный тип.** Вывод из кода: если модуля нет, `String.to_existing_atom/1` поднимает `ArgumentError` [6].
Опции пропуска не найдено.
- Агрегат: `aggregate_module.apply(state, data)` вызывается без fallback [8]. Вывод: событие без клаузы
  даёт `FunctionClauseError`.
- Обработчик: `__before_compile__` генерирует `def handle(_event, _metadata), do: :ok` [4].
- Process manager: генерируется `def interested?(_event), do: false` [9].

**Copy-transform.** Встроенного нет, апкаст работает только на лету. EventStore умеет `delete_stream`
(`:soft` / `:hard`), hard-удаление по умолчанию выключено [10]. Гайд требует не менять формат сериализации
после выхода в прод, иначе хранилище придётся мигрировать [11].

**Снапшоты.**
- Опция агрегата `snapshot_version`. `validate_snapshot` сравнивает `metadata["snapshot_module_version"]`
  с ней и при расхождении возвращает `{:error, :outdated_snapshot}` [12].
- После ошибки `populate/1` берёт `struct(aggregate_module)` и проигрывает поток с нуля [8].
- Гайд: «Whenever you change the structure of an aggregate's state you **MUST** increment the `snapshot_version`» [13].
- Апкастер к снапшоту не применяется: `Upcast` работает только с `RecordedEvent` [2]. События после снапшота
  проходят `stream_forward` и апкастятся [3][8].

**Проекции** получают уже апкастнутые события. Для пересборки есть reset обработчика (mix task, подписка
заново с `start_from`) [7].

## Marten

**Хранение.** В `mt_events` лежат `type` (event type name, по умолчанию snake_case имени класса)
и `mt_dotnet_type` (assembly-qualified имя) [14].

**Место и вход.** Апкаст выполняется при чтении строки. `EventDocumentStorage.Resolve(DbDataReader)` находит
mapping по `type` и вызывает `ReadEventData` [15]. Если зарегистрирована `JsonTransformation`, данные читает
`jsonTransformation.FromDbDataReader(serializer, reader, 0)` [16]. Документация: «performed on the fly each time
the event is read… a pluggable middleware between the deserialization and application logic» [14].

Вход бывает двух видов [14]:
- объект старого CLR-типа: `Upcast<TOld, TNew>`, `EventUpcaster<TOld, TNew>`;
- сырой JSON (`JObject` / `JsonDocument`) — «if we don't want to keep the old CLR class».

Регистрация идёт по event type name, при этом mapping апкастера помечается `IsUpcastTarget` и перекрывает
fallback по `mt_dotnet_type` (#4680) [17]. Есть async-апкастеры с предупреждением: «Upcasting code is run each time
the event is deserialized» — риск N+1; async-апкастер при синхронном чтении бросает исключение [14].

**Версия схемы** определяется именем типа. Явное имя в `Upcast` нужно, «if you changed the event schema more than
once, and the old CLR class doesn't represent the initial event type name» [14]. Поля версии не найдено.

**Переименование.**
- Сменился namespace — сопоставление по имени класса.
- Сменилось имя класса — `MapEventType<New>("order_status_changed")`; старый и новый хранятся под одним
  `type` [14].
- Сменилось имя свойства — атрибут сериализатора; новые события по-прежнему пишут старое имя,
  и LINQ-запрос по новому ничего не найдёт [14].

**Неизвестный тип.** Нет mapping — Marten пробует `mt_dotnet_type` через `Type.GetType`; не нашёл —
`UnknownEventTypeException` [15][17].
- Перехват есть только в `EventLoader` async-демона [18]. Вывод: при live-агрегации исключение уходит вызывающему.
- `SkipUnknownEvents`, `SkipSerializationErrors` («errors from serialization or upcasters») и `SkipApplyErrors`
  по умолчанию `True` в continuous-режиме и `False` при rebuild. Без skip проекция встаёт на паузу,
  rebuild останавливается [19].

**Copy-transform.** Документация советует не менять прошлое: «The best strategy is not to change the past data but
compensate our mishaps»; предлагает архивировать короткоживущие потоки и держать graceful period с двумя схемами [14].
- Архивирование помечает поток `is_archived`, демон его игнорирует [20].
- Stream compacting (8.0, `CompactStreamAsync` до версии или времени, с `Archiver`) сжимает старую часть потока [21].
- Правка через SQL: «we urge you to be cautious» [20].
- Встроенного copy-replace не найдено.

**Снапшоты и проекции.**
- Снапшот — это проекция: `opts.Projections.Snapshot<T>(SnapshotLifecycle.Inline)`, «"Snapshot" now means
  "a version of the projection from the events"» [22].
- Inline- и async-проекции пересобираются через `RebuildProjectionAsync` [23].
- Blue/green: увеличенный `ProjectionVersion` пишет в отдельные таблицы и догоняет историю в async,
  пока старая версия обслуживает трафик [23].
- Апкаст позволяет «keep only the last version of the event schema in our stream aggregation or projection
  handling» [14].

## Emmett

**Место и вход.** Опция `schema.versioning.upcast?: (event: StoredEvent) => StreamEvent` на чтении и
`downcast?: (event: StreamEvent) => StoredEvent` на записи [24].
- PostgreSQL `readStream` собирает `{type, data, metadata}` из строки и вызывает
  `upcastRecordedMessage(event, options?.schema?.versioning)` [25].
- `CommandHandler` передаёт `schema` в `aggregateStream({ read: { schema } })` [26].
- Процессоры и проекции апкастят до фильтра `canHandle` [27].

На входе — всё записанное сообщение (plain object из jsonb) или payload. Апкастер один на поток: в примере
релиза это `switch (event.type)` [28][29]. Релиз 0.42.0: «allows both event payload evolution, but also mapping of
types that are not supported by JSON, like `Date`, `Bigint`» [29].

**Версия схемы.** В таблице есть `message_schema_version TEXT NOT NULL` [30], но `appendToStream` пишет константу
`'1'` для всех сообщений [31]. `readStream` колонку выбирает, но в событие не кладёт [25] (вывод).
Версию распознаёт пользовательский `upcast` — по `type` и содержимому.

**Переименование и удаление.** Механизма сопоставления типов нет. Вывод: сигнатура `upcast` позволяет вернуть
другой `type`.

**Неизвестный тип.**
- `evolve` пишет пользователь; в документации это `default: return summary` [32].
- PostgreSQL-проекция вызывается, только если тип есть в `canHandle` [33]; процессор пропускает сообщение
  при `!canHandle.includes(upcasted.type)` [27].

**Copy-transform и снапшоты** не найдены.

## Message DB (и Eventide)

**Хранилище.** Одна таблица `message_store.messages` с колонками `type text NOT NULL`, `data jsonb`,
`metadata jsonb`, без версии схемы [34]. API `write_message(id, stream_name, type, data, metadata,
expected_version)` [35]. В README и функциях апкаста или сериализатора нет: хранилище только хранит JSON.
Message DB выделена из Eventide [35].

**Eventide.** В метаданных есть атрибут `schema_version`: «Version identifier of the message schema itself»;
метаданные описаны как «data about messaging machinery, like message schema version» [36]. В `messaging` он объявлен
как `attribute :schema_version, String` [37]. Где библиотека его выставляет или читает, не найдено.

**Неизвестный тип.**
- Обработчик: блоки `handle` по классу сообщения и fallback-метод `handle(message_data)` с сырым `MessageData`
  по `type`. Опция `strict` «causes an error when no handler block for the message is implemented» [38].
- Проекция сущности: «An event is ignored if the projection doesn't have a matching `apply` block»,
  есть fallback `apply(message_data)` [39].

**Снапшоты.** Отдельный поток `someEntity:snapshot-123`, сущность сериализуется в JSON через Transform-протокол;
«Snapshots are not expired», «no automatic disposal of previous snapshots» [40]. Версионирование снапшотов
и copy-transform не найдены.

## Greg Young, «Versioning in an Event Sourced System»

Полный текст доступен в онлайн-читалке leanpub. Разобраны главы Basic Type Based Versioning, Weak Schema,
General Versioning Concerns (Snapshots), Copy and Replace, Cheating.

**Типовое версионирование** [41].
- Версия в имени типа: `InventoryItemDeactivated_v1` / `_v2`.
- Правило: «A new version of an event must be convertible from the old version of the event. If not, it is not
  a new version of the event but rather a new event».
- Апкаст при чтении: «upcast the version of the event as we read it from the Event Store… passed through some
  converters». После него обработчик `_v1` в домене можно удалить.
- Недостаток: «If a consumer does not have the type, it will not be able to even deserialize that event», в том
  числе в проекциях.
- Double write («only handle the version of the event you understand and ignore all others») «not recommended
  for Event Sourced systems» из-за replay проекций.
- Итог главы: «You should generally avoid versioning your system via types in this way».

**Weak schema** [42].
- Правила маппинга: ключ есть в JSON и в типе — значение из JSON; только в JSON — NOP; только в типе — default.
- Цена: «you are no longer allowed to rename something».
- Hybrid-schema: обязательные поля плюс опциональные.
- Wrapper над JSON сохраняет непонятые поля.
- «Most production systems use mapping with either XML or json… The upcasting system is often difficult to maintain
  amongst consumers».

**Снапшоты** [43].
- Снапшот «will not be able to be upgraded but will instead need to be rebuilt»: новое поле состояния берётся
  из событий, поэтому нужен полный replay.
- Обычный путь — пересобрать и потом удалить старые снапшоты.
- При сосуществовании версий снапшоты v1 и v2 хранятся рядом.
- Persisted snapshots «often not worth implementing».

**Copy-Replace** [44].
- Старый поток читается, по пути трансформируется (удалить событие — просто не копировать) и пишется в новый;
  старый удаляется. Есть вариант in-place с «truncate before».
- «Copy-Replace is the nuclear-option of versioning»: потребители видят переписанные события как новые.
- На живой системе нужны указатель `StreamMovedTo`, `ExpectedVersion` на записи и событие `Invalidated`
  для проекций.

**Copy-Transform** [45].
- Всё хранилище мигрирует в новое окружение, затем Big Flip.
- «all of the issues dealing with projections from Copy-Replace go away. Every projection is rebuilt from scratch».
- Цена: объём (10 TB — «a week or two»), двойное железо, трудности с распределёнными read models.
- Versioning Bankruptcy — перенос `Initialized`-событий вместо истории.

## Сравнительная таблица

| Аспект | Commanded + EventStore | Marten | Emmett | Message DB / Eventide | Young |
|---|---|---|---|---|---|
| Место апкаста | после десериализации, в чтении потока и подписках | в `Resolve` при чтении строки, вместо десериализации | опция чтения store / handler / processor | нет (store); fallback `handle`/`apply` по `type` | конвертеры при чтении |
| Вход | struct + metadata | старый CLR-объект или сырой JSON | весь записанный объект (type/data/metadata) | `MessageData` (сырой) | старый тип / JSON-маппинг |
| Версия схемы | тип-модуль | event type name | пользовательская функция; колонка всегда `'1'` | `schema_version` в metadata, авто-использование не найдено | `_vN` в типе или weak schema |
| Переименование типа | апкастер старый struct → новый, модуль остаётся | `MapEventType` | вручную в `upcast` | — | новый тип / copy-replace |
| Неизвестный тип, агрегат | `ArgumentError` (вывод) | исключение | решает `evolve` | `apply` игнорирует | тип нужен для десериализации |
| Неизвестный тип, проекция | нет struct — ошибка; нет клаузы — `:ok` | skip в continuous, пауза при rebuild | фильтр `canHandle` | игнорируется, `strict` — ошибка | double write: игнорировать |
| Copy-transform | нет; `delete_stream` hard | нет; archive / compact | нет | нет | copy-replace, copy-transform |
| Снапшоты | `snapshot_version`, устаревший игнорируется | снапшот = проекция, rebuild / `ProjectionVersion` | нет | поток снапшотов, без версии | пересборка, версии рядом |

## Развилки

1. **Апкаст над сырым конвертом до `load_payload`** (Marten raw JSON, Emmett).
   - Цена: работает на каждом чтении, логика строковая.
   - Плюс: старые `Payload`-модули и клаузы можно удалять.
   - Конфликт с `14-events-outbox.md`: «тег и clause `load_payload` остаются навсегда» — остался бы только тег
     в апкастере; «переименование wire-тега запрещено» — стало бы технически возможным.
   - Golden-фикстуры совместимы: `InCodec.load` пройдёт через апкаст.
2. **Апкаст над десериализованной структурой** (Commanded).
   - Старые модули и клаузы живут вечно — это совпадает с текущими правилами.
   - Цена: двойная загрузка, у апкастера нет доступа к полю, которого нет в struct.
3. **Версия в имени типа** (Young type-based, Marten через имя).
   - Уже совпадает с правилом «несовместимое изменение — это новый тип события».
   - Цена по Young: разрастание `apply`-клауз и обязанность обновить потребителей раньше продюсера.
4. **Явный дискриминатор версии.**
   - Поле в конверте или колонке (Eventide `schema_version`, Emmett `message_schema_version`) — ни в одном
     источнике механизм его не использует. Цена: новое поле конверта меняет wire-формат outbox.
   - `aggregate_version` из текущего правила — ни один источник так версию схемы не определяет. У Commanded
     `stream_version` лишь доступен апкастеру в metadata.
5. **Неизвестный тип.**
   - Ошибка: Commanded; Marten при live и rebuild.
   - Пропуск: Marten continuous; Eventide; Emmett `canHandle`.
   - В текущем `:core` подписчик получает `:unknown_event_type`. Поведение при восстановлении агрегата не задано.
6. **Copy-replace / copy-transform.**
   - По Young это «nuclear option»: outbox уже доставил старые события в брокер, и переписанная история разойдётся
     с тем, что видели потребители.
   - Конфликт с «Строки в event store живут вечно» и с unique `(aggregate_id, aggregate_version)` при in-place.
   - Альтернативы Marten — archive / compact.
7. **Снапшоты при эволюции.**
   - Версия снапшота с игнорированием устаревших (Commanded).
   - Хранение версий рядом (Young).
   - Снапшот как проекция с rebuild или `ProjectionVersion` (Marten).
   - Ни один источник не апкастит сам снапшот.
8. **Downcast на записи** (Emmett) — для сосуществования версий кода при rolling deploy. Цена — вторая функция
   на каждый тип.

## Не найдено

- Commanded / EventStore: пропуск неизвестных типов; встроенная миграция истории; пример `TypeProvider`
  для переименования.
- Marten: поле версии схемы в метаданных; встроенный copy-replace. Детали `CompactStreamAsync` дальше
  вступления не изучались.
- Emmett: раздел о версионировании в markdown-документации на теге 0.42.4 (источник — релиз-ноты 0.42.0 и код);
  чтение `message_schema_version`; снапшоты; copy-transform.
- Message DB: какое-либо версионирование в store. Где Eventide выставляет или читает `schema_version`:
  поиск по организации нашёл только объявление атрибута и тесты.
- Young: главы Negotiation, Internal vs External Models, Versioning Process Managers не разбирались. Отдельной
  рекомендации о неизвестном типе при восстановлении агрегата в прочитанных главах нет.

## Источники

1. commanded `lib/commanded/event/upcaster.ex` — https://github.com/commanded/commanded/blob/v1.4.11/lib/commanded/event/upcaster.ex
2. commanded `lib/commanded/event/upcast.ex` — https://github.com/commanded/commanded/blob/v1.4.11/lib/commanded/event/upcast.ex
3. commanded `lib/commanded/event_store.ex` (`stream_forward/4`) — https://github.com/commanded/commanded/blob/v1.4.11/lib/commanded/event_store.ex
4. commanded `lib/commanded/event/handler.ex` (L907–925, L1075), `aggregates/aggregate.ex` (L389), `process_managers/process_router.ex` (L193) — https://github.com/commanded/commanded/tree/v1.4.11/lib/commanded
5. eventstore `lib/event_store/recorded_event.ex` (L58–64), `streams/stream.ex` (L292) — https://github.com/commanded/eventstore/blob/v1.4.8/lib/event_store/recorded_event.ex
6. commanded `serialization/json_serializer.ex`, `serialization/module_name_type_provider.ex`, `event_store/type_provider.ex` — https://github.com/commanded/commanded/tree/v1.4.11/lib/commanded/serialization
7. commanded `guides/Events.md` («Upcasting events», «Reset an EventHandler») — https://github.com/commanded/commanded/blob/v1.4.11/guides/Events.md
8. commanded `lib/commanded/aggregates/aggregate_state_builder.ex` — https://github.com/commanded/commanded/blob/v1.4.11/lib/commanded/aggregates/aggregate_state_builder.ex
9. commanded `lib/commanded/process_managers/process_manager.ex` (L573) — https://github.com/commanded/commanded/blob/v1.4.11/lib/commanded/process_managers/process_manager.ex
10. eventstore `guides/Usage.md` («Soft delete», «Hard delete») — https://github.com/commanded/eventstore/blob/v1.4.8/guides/Usage.md
11. commanded `guides/Serialization.md` — https://github.com/commanded/commanded/blob/v1.4.11/guides/Serialization.md
12. commanded `lib/commanded/snapshotting.ex` — https://github.com/commanded/commanded/blob/v1.4.11/lib/commanded/snapshotting.ex
13. commanded `guides/Aggregates.md` («Rebuilding an aggregate snapshot») — https://github.com/commanded/commanded/blob/v1.4.11/guides/Aggregates.md
14. Marten docs «Events Versioning» — https://martendb.io/events/versioning.html (исходник `docs/events/versioning.md` @ V9.33.0)
15. marten `src/Marten/Events/EventDocumentStorage.cs` (`Resolve`, L339–520) — https://github.com/JasperFx/marten/blob/V9.33.0/src/Marten/Events/EventDocumentStorage.cs
16. marten `src/Marten/Events/EventMapping.cs` (L219–243) — https://github.com/JasperFx/marten/blob/V9.33.0/src/Marten/Events/EventMapping.cs
17. marten `src/Marten/Events/EventGraph.cs` (L762–788 `Upcast`, L981 `UnknownEventTypeException`) — https://github.com/JasperFx/marten/blob/V9.33.0/src/Marten/Events/EventGraph.cs
18. marten `src/Marten/Events/Daemon/Internals/EventLoader.cs` (L272–285) — https://github.com/JasperFx/marten/blob/V9.33.0/src/Marten/Events/Daemon/Internals/EventLoader.cs
19. Marten docs «Async Daemon — Error Handling» — https://martendb.io/events/projections/async-daemon.html
20. Marten docs «Archiving Event Streams» — https://martendb.io/events/archiving.html
21. Marten docs «Stream Compacting» — https://martendb.io/events/compacting.html
22. Marten docs «Projections» — https://martendb.io/events/projections/
23. Marten docs «Rebuilding Projections» (Blue/Green, `ProjectionVersion`) — https://martendb.io/events/projections/rebuilding.html
24. emmett `src/packages/emmett/src/eventStore/eventStore.ts` (L121–141) — https://github.com/event-driven-io/emmett/blob/0.42.4/src/packages/emmett/src/eventStore/eventStore.ts
25. emmett `src/packages/emmett-postgresql/src/eventStore/schema/readStream.ts` (L22, L61, L93) — https://github.com/event-driven-io/emmett/blob/0.42.4/src/packages/emmett-postgresql/src/eventStore/schema/readStream.ts
26. emmett `src/packages/emmett/src/commandHandling/handleCommand.ts` (L64–76, L126–137) — https://github.com/event-driven-io/emmett/blob/0.42.4/src/packages/emmett/src/commandHandling/handleCommand.ts
27. emmett `src/packages/emmett/src/processors/processors.ts` (L246, L514–524) — https://github.com/event-driven-io/emmett/blob/0.42.4/src/packages/emmett/src/processors/processors.ts
28. emmett `src/packages/emmett/src/eventStore/versioning/upcasting.ts` — https://github.com/event-driven-io/emmett/blob/0.42.4/src/packages/emmett/src/eventStore/versioning/upcasting.ts
29. Emmett release 0.42.0 (PR #292) — https://github.com/event-driven-io/emmett/releases/tag/0.42.0
30. emmett `src/packages/emmett-postgresql/src/eventStore/schema/tables.ts` (L45) — https://github.com/event-driven-io/emmett/blob/0.42.4/src/packages/emmett-postgresql/src/eventStore/schema/tables.ts
31. emmett `src/packages/emmett-postgresql/src/eventStore/schema/appendToStream.ts` (L321) — https://github.com/event-driven-io/emmett/blob/0.42.4/src/packages/emmett-postgresql/src/eventStore/schema/appendToStream.ts
32. Emmett docs «Getting Started» — https://event-driven-io.github.io/emmett/getting-started.html
33. emmett `src/packages/emmett-postgresql/src/eventStore/projections/postgreSQLProjection.ts` (L99–101) — https://github.com/event-driven-io/emmett/blob/0.42.4/src/packages/emmett-postgresql/src/eventStore/projections/postgreSQLProjection.ts
34. message-db `database/tables/messages.sql` — https://github.com/message-db/message-db/blob/v1.3.0/database/tables/messages.sql
35. message-db `README.md` — https://github.com/message-db/message-db/blob/v1.3.0/README.md
36. Eventide docs «Metadata» — http://docs.eventide-project.org/user-guide/messages-and-message-data/metadata.html
37. eventide-project/messaging `lib/messaging/message/metadata.rb` (L41) — https://github.com/eventide-project/messaging/blob/82ae099da1c73af8458284c5676feac185b1d367/lib/messaging/message/metadata.rb
38. Eventide docs «Message Handlers» — http://docs.eventide-project.org/user-guide/message-handlers.html
39. Eventide docs «Projection» — http://docs.eventide-project.org/user-guide/projection.html
40. Eventide docs «Snapshotting» — http://docs.eventide-project.org/user-guide/entity-store/snapshotting.html
41. G. Young, «Basic Type Based Versioning» — https://leanpub.com/read/esversioning/leanpub-auto-basic-type-based-versioning
42. G. Young, «Weak Schema» — https://leanpub.com/read/esversioning/leanpub-auto-weak-schema
43. G. Young, «General Versioning Concerns» → Snapshots — https://leanpub.com/read/esversioning/leanpub-auto-general-versioning-concerns
44. G. Young, «Copy and Replace» — https://leanpub.com/read/esversioning/leanpub-auto-copy-and-replace
45. G. Young, «Cheating» → Copy-Transform, Versioning Bankruptcy — https://leanpub.com/read/esversioning/leanpub-auto-cheating
