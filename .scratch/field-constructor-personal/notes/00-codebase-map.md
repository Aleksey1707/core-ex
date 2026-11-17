# Карта кода под рефакторинг «общий конструктор полей + рекурсивные ПДн-места»

База: `field-constructor-personal` после слияния тикета 01 (IR `Core.Field` + `Core.Field.Meta` уже есть).
Строки указаны на момент составления; перед правкой перепроверять.

## 1. Роли и точки входа

- `Core.Struct` (`lib/core/struct.ex`) — `use`, опции `fields:`/`events:`; `fields!/1` (грамматика
  `Field.normalize!(spec, :struct, …)`), `default!/2` (типизированное значение), `declared_fields/1`
  (`@core_struct_fields`), `__struct_fields__/0`, `__struct_events__/0`, `typespec/1`, `@enforce_keys`,
  `defstruct`; `@type t` собирает `Core.Codec.Field.typespec/1`.
- `Core.Es.Event.Payload` (`lib/core/es/event/payload.ex`) — `use fields:`; `fields!/1` + `check_subject!/3`
  (семантика `subject:`), `uuid_prim?/1`, `typespec/1`, `new_guard/1`, `dump_args/3`/`dump_guard/1`/
  `dump_body/1` (маркеры), `load_body/2` (разбор `{"$pd": …}`), `marker_error/3`, `redact/1`;
  `__es_payload_fields__/0`.
- `Core.Codec.Plugin` (`lib/core/codec/plugin.ex`) — опции `types:`, `loadable:`, `union:`, `fields:`,
  `variants:`; генерирует `dump/2`/`load/3` из `@codec_fields`/`@codec_variants`; `__codec_types__/0`,
  `__codec_union__/0`, `__codec_variants__/0`, `__codec_pattern__/1`, `__codec_check__/1`, `type/1`,
  `types/0`. Подсборки: `plugin/fields.ex` (значение поля: dump/load, типы, guard, new),
  `plugin/fields/kind.ex` (операции вида), `plugin/variants.ex` (адреса, dump/load варианта и
  семейства), `plugin/opts.ex`, `plugin/redump.ex`.
- `Core.View` (`lib/core/view.ex`) — `use fields:`/`forms:`; разбор — `Core.View.Opts` (свой, через
  `Core.Codec.Field.kind_key!/3`), дамп — `Core.View.Dumper`, значение поля — `Core.View.Field`;
  `new/1` (keyword), `__view__/0`, вложенный `Codec` (dump-only).
- `Core.Labels.Fields` (`lib/core/labels/fields.ex`) — `use labels:` / `fields:` / `change:` / `value:`;
  читает `Struct.declared_fields/1`, `Payload.declared_fields/1`, `ValueChanged.declared/1`,
  `Codec.Field.struct_fields/1`; `__label_fields__/0`, `__label_specs__/0`, `__label_change__/0`;
  полнота — `@after_compile`, обходы — `Labels.Walk`, сведения — `Labels.Details`, ссылки — `Labels.Refs`.
- `Core.Es.Event.Codec` (`lib/core/es/event/codec.ex`) — `use family:, type:, tags:, upcasts:`;
  `derived/1`, `dump_payload_clause/3`, `load_payload_clause/3`, `derived_clauses/0`, конверт
  (`dump_envelope/4`, `load_by_tag/5`, `load_header/4`, `build/3`, `to_fields/1`, `from_fields/1`),
  `__es_subjects__/0` (`:320-328`), `check_facade!/2`, `codec?/1`.
- `Core.Es.ValueChanged` (`lib/core/es/value_changed.ex`) — `type:`/`nilable:`, `fields/2` строит
  спеку `old_value`/`new_value`, `__es_value_changed__/0`, `new/2`.
- `Core.Es.Event.Family` (`lib/core/es/event/family.ex`) — семейство событий, `aggregate_id:`/`by:`/`codec:`.

## 2. Грамматика `Core.Codec.Field` (`lib/core/codec/field.ex`)

- `%Field{name, spec, optional?, wire, default, subject, destroyable}`; после 01 есть и `personal`
  (в IR `Core.Field`); `spec` — `{:prim|:enum|:entity|:union, mod}`, `{:list|:set, spec}`,
  `{:map, key, value}`, `{:type, atom}` (+ `{:personal, spec}` в IR).
- Виды: базовые `prim enum entity union list set map type`; у View ещё `view form jsonb`.
- Режимы: `fields!/2` (плагин), `normalize!/3` (`:payload | :plugin | :dump_only | :labels | :struct`),
  `variant_fields!/4`.
- Публичные `@doc false`, которые нельзя ломать без причины: `kinds/0,1`, `kind_key!/3`,
  `values/1`, `children/1`, `struct_module!/2`, `value_spec/2`, `struct_fields/1`, `map_opts!/2`,
  `check_map_key!/3`, `subjects/1`, `destroyable_places/1`, `typespec/1`, `union_type/1` (после 01).
- Внутри: `kind_key!/3` (allowlist хоста), `type_fields!/5` + `check_struct!/4` + `check_shapes!/3`,
  `spec_fields!`, `field!/4`, `pop_destroyable!` (удаляется в 02), `spec!/4`, `kind_spec!` по видам,
  `element_spec!/5`, `optional!/2`, `wire!/3`, `default!/5`, `subject!/2`, `check_payload_wires!/2`,
  `check_default_wire!/4`, `string_prim?/1`.
- Вызовы (grep на базу): `normalize!/3` — `struct.ex:307`, `payload.ex:120`, `labels/fields.ex:313`,
  `value_changed.ex:93`; `typespec/1` — `struct.ex:194`, `payload.ex:99,205`, `value_changed.ex:50,60`;
  `subjects/1` — `payload.ex:83,203,244,299`, `codec.ex:414`, `event.ex:291`, `personal/test.ex:139`,
  `projection_case.ex:387`; `destroyable_places/1` — `es/cmd.ex:95`; `struct_fields/1` — `es/aggregate.ex:226`,
  `es/cmd.ex:91`, `repo/pg/state_stored.ex:276`.

## 3. Путь ПДн сегодня (единица шифрования — поле нагрузки верхнего уровня целиком)

### 3.1 Маркер, уничтоженное значение, порт
- `lib/core/es/personal/marker.ex:18` `%Marker{subject, value, destroyed}`, `:28` Inspect, `:40`
  Jason.Encoder (исключение без значения).
- `lib/core/es/personal/destroyed.ex:11` пустой struct, `@type t`.
- `lib/core/es/personal/port.ex:30` `seal/1`, `:35` `open/1`, `:46` `index/1`, `:51` `destroy/1`,
  `:57` `call/2` (telemetry), `:86` `emit_outcomes/1`, `:107` `address/1` —
  `<<len::32, part::binary>>` на часть (AAD можно удлинять до пути).

### 3.2 Запись
- `payload.ex:266-277` `dump_body/1` + `marker/4` `:304-319` — решение «шифруется поле целиком».
- `payload.ex:219-226` `new_guard/1`, `:257-261` `dump_guard/1`, `:435-441` `subject_guards/1`.
- `payload.ex:202-208` `typespec/1` — `| Destroyed.t()` по списку `subject:`.
- `codec.ex:320-328` `__es_subjects__/0`, `subjects/1` `:412`.
- `wire.ex:26-36` `seal_payloads/1` (только верхний уровень, `fields/1` `:151`), `item!/3` `:51-58`
  (уничтоженный маркер → `ArgumentError`), `address/2` `:156` = `Port.address([event_id, key])`;
  `seal_records/1` `:41-47` (outbox); `replace_markers/2` `:67-75`.
- `store.ex:268-271` `seal_rows/1` (один batch на пачку `es_events`), `append/5` `:219-228`.
- `store/write.ex:34-49` `append/4`: outbox.from_events → append → резервы → `seal_records` → outbox_repo.

### 3.3 Чтение
- `wire.ex:86-98` `open_wires/2`, `:103-112` `open_items/2`, `:143-147` `sealed_fields/1` (верхний
  уровень `wire["payload"]`), `:132-139` `put_opened/2`.
- `store.ex:593` `load_rows/3`, `:602` `load_fold_rows/4`, `:619` `load_batch/2`, `:628` `load_wires/2`,
  `:637` `load_event/3`, `:642-645` `load_entries/3`, `:653-661` `load_wire/3`, `:663` `unreadable/2`,
  `:674` `upcast_raised/3` (редакция на расшифрованном конверте).
- `event/message.ex:44` `load/2`, `:62-67` `load_wire/3`, `:69` конверт без `event_id`.
- `payload.ex:351-378` `load_step/3` + `destroyed_clause/1`, `:380-389` `redacted/2`, `:421-429` `redact/1`.
- `personal/test.ex:46-59` `destroyed/2`; `aggregate/load/engine.ex:295-299` `destroyed_value?/2`
  (верхний уровень — решение «снапшот не писать»).

### 3.4 Снапшоты
- `aggregate/repo/pg/snapshot.ex:52` `opts!/3` (вход — `__es_subjects__/0`), `:77-91` `sealed!/2`
  (запрет субъекта не `:aggregate_id`), `:104` `marker/1`, `:119` `sealed/4`, `:131` `opened/3`,
  `:149` `fold/4`, `:259-270` `sealed_rows/3`, `:273` `without_destroyed/4`, `:350` `aad/4`.
- `aggregate/repo/pg.ex:101-107` (правило снапшота), `:370` (передача карты субъектов).
- `aggregate/process.ex:250` — `personal:` процесса по `__es_subjects__() != %{}`.

### 3.5 Подписи, сведения, схема
- `labels/walk.ex:74` `%Destroyed{}` лист; `labels/details.ex:157` `kind: :destroyed`;
  `labels/refs.ex:100` уничтоженное не даёт ссылку.
- `web/event.ex:414` `to_wire/5`, `:437-442` `open/1`/`open_value/1` (маркер → `{"$destroyed": true}`,
  только верхний уровень); схема `"Destroyed"` — `web/event/schema.ex:22,58`; `web/event/details.ex:28`.
- `es/event/payload.ex:130-176` адреса субъекта, `:178` `personal_prim/1` (по `values/1`, не
  рекурсивно в `entity:`/`union:`), `:189` `uuid_prim?/1`; `es/event.ex:275-292` `check_subject!/2`;
  `es/projection.ex:427-452` `personal!/*`; `key_store.ex:66` `subject_destroyed/1`.

### 3.6 Case-модули и фикстуры
- `es/event_compat_case.ex:284` `check_personal_fields/3`, `:314-331` `personal_values/2` (единственный
  рекурсивный обход), `:338` `check_destroyed_fixtures/2`, `:350` `check_destroyed_load/3`,
  `:371` `check_destroyed/3`, `:379-384` `check_all_destroyed/2`, `:437` `subjects/2`.
- `es/projection_case.ex:272` `check_personal/2`, `:311-325` `destroy_subjects/4`, `:327` `left/3`,
  `:374` `personal_fixtures/2`, `:383` `subject_wires/1`, `:394` `markers/2`.
- `es/personal/test.ex:46` `destroyed/2`, `:83` `fixtures/1`, `:95` `body/2`, `:128` `key_destroyed/2`,
  `:137` `subject_fields/1`.
- Golden: `test/support/fixtures/events/account/destroyed/account.holder_set.json`,
  `test/support/fixtures/events_sealed/account/account.holder_set.json`,
  `test/support/personal_golden_fixture.ex`.

### 3.7 Куда встаёт рекурсивный обход
- Запись: `payload.ex:266`/`:304`; `wire.ex:26`,`:151`,`:67`; `store.ex:268`; `wire.ex:41`.
- Чтение: `wire.ex:86`,`:143`,`:132`; `payload.ex:351`; `store.ex:642`.
- Guard записи: `payload.ex:219`,`:257`,`:435`.
- Интроспекция: `codec.ex:320` → `__es_personal__/0`; потребители — `snapshot.ex:52`,`:77`,
  `projection.ex:427`, `process.ex:250`, `engine.ex:295`.

## 4. Read-путь

- `Core.Web.Event` — `lib/core/web/event.ex:181` `__using__/1`, `:414` `to_wire/5`, `:437` `open/1`,
  `:440` `open_value/1`, `:325` `narrow/2`, `:343` `schemas/0`, `:371` `detail/0`, `:391` `variant/2`,
  `:288` `page/2`.
- `Core.Labels.Details` — `lib/core/labels/details.ex:113` `build/1`, таблица видов `moduledoc:11-32`,
  `:157` `leaf/1`, `:138-152` `item/1`, `:202-204` `type_kind/1`.
- `Core.Labels.Walk` — `:47` `values/2`, `:74` `data/3`.
- `Core.Web.Event.Schema` — `:22`, `:184` `properties(:destroyed, …)`, `:187` `required(:destroyed)`.
- `Core.View` (`lib/core/view.ex:129` `shape/2`) `%Destroyed{}` не знает — проекция преобразует сама.

## 5. Тесты

### 5.1 Шов объявления
- `test/core/codec/field_test.exs` (286) — нормализатор: форма поля, режимы, `wire:`, `default:`,
  `subject:`, «вид × хост».
- `test/core/struct_test.exs` (635) — `use Core.Struct`, `default:` и отказы (117-342), `events:`,
  `@type t` (352-450, читает байткод через `Code.Typespec`), отказы (451+). Цель 02.
- `test/core/codec/plugin_test.exs` (323) — опции, выражения, «ожидается литерал», покрытие клауз.
- `test/core/codec/plugin_fields_test.exs` (1132) — round-trip `fields:`, виды, `set:`, `map:`,
  смешанный плагин, сверка со struct.
- `test/core/codec/plugin_kind_test.exs` (116) — «вид × операция».
- `test/core/codec/plugin_variants_test.exs` (567) — варианты, `union:`-поле, `__codec_variants__/0`,
  отказы адресов. База 03. `plugin_redump_test.exs` (553) — спека redump.
- `test/core/view_test.exs` (710), `test/core/view/field_test.exs` (104). Шов 06.
- `test/core/es/event/payload_test.exs` (217), `payload_kind_test.exs` (236),
  `payload_personal_test.exs` (268). Шов 05.
- `test/core/es/value_changed_test.exs` (154).
- `test/core/labels/fields_test.exs` (972), `labels/kind_table_test.exs` (145). Шов 06/10.
- `test/core/es/event/codec_test.exs` (687), `event/family_test.exs` (143),
  `event/derived_payload_test.exs` (287).

### 5.2 Тесты данных
- `es/event/codec_personal_test.exs` (278) — `__es_subjects__/0`, dump-маркеры, load `{"$pd": nil}`.
- `es/personal/events_test.exs` (350), `events_projection_test.exs` (276), `events_race_test.exs` (137).
- `es/personal/snapshot_test.exs` (271), `projection_test.exs` (77), `destroy_key_test.exs` (141),
  `destroy_key_failure_test.exs` (57), `key_reservation*_test.exs`.
- `es/personal/key_store/*` (`pg_test`, `race_test`, `rewrap_test`, `contract_test`, `config_test`),
  `port_test.exs` (75), `test_test.exs` (91).
- `es/projection_case_test.exs` (305), `event_compat_case_test.exs` (182).
- Тонкие обёртки `use ...Case`: `es/account_compat_test.exs`, `es/event_fixture_compat_test.exs`,
  `es/fixture_projection_case_test.exs`, `es/personal/event_compat_test.exs`,
  `es/personal/key_store/contract_test.exs`.
- `es/event/message_test.exs` (267), `es/store_test.exs`, `store_race_test.exs`, `store/write_test.exs`.
- `aggregate/repo/pg/snapshotted_test.exs` (468), `aggregate/load*_test.exs`.
- `web/event_test.exs` (513), `web/event/details_test.exs` (477), `web/event/schema_test.exs` (81).
- `labels/details_test.exs` (593), `labels/refs_test.exs` (392), `labels/completeness_case_test.exs` (203).
- `prim/personal_test.exs`; `mix/tasks/es_personal_rewrap_test.exs`.

### 5.3 Test support
- `struct_fixture.ex`, `view_fixture.ex` (в ebin: `@type t` читается из байткода).
- `codec_fixture.ex` + `codec_fixture/{internal,external}.ex` (`plugins/0` — реестр плагинов).
- `es_fixture/account.ex` (ручной struct состояния, `holder: Holder.t() | Destroyed.t() | nil`),
  `es_fixture/event/*`, `es_fixture/event/codec.ex` (`upcasts:`), `es_fixture/catalog.ex`,
  `es_fixture/payload_kinds.ex`, `es_fixture/{broken,personal_broken}_projection.ex`.
- `personal_broken_fixture.ex`, `personal_golden_fixture.ex`, `labels_fixture.ex`,
  `labels_broken_fixture.ex`, `derived_fixture.ex`, `event_fixture.ex` + `event_fixture/event/*`,
  `state_stored_fixture.ex`, `web_event_fixture.ex`, `es_store_rows.ex`, `data_case.ex`, `test_repo*.ex`.

## 6. Фикстура-потребитель `fixtures/consumer`

- `fixtures/consumer/README.md:1-105` — отдельное приложение с `{:core, path: "../.."}`, окружение
  `dev`. Шаг `make consumer-check`: `boundary_lint.exs --consumer` → `spec_lint.exs` →
  `mix deps.loadpaths` → `mix run --no-start --no-compile check.exs`.
- `scripts/boundary_lint.exs:23` `@consumer_dirs ["lib"]`, `:50` `run([])`, `:54` `abort/1`.
- Храповик вывода типов — `fixtures/consumer/check.exs` (180): маркеры `# expect:` (`:23` регексп,
  `:123-142` привязка к следующей строке, `:147` `reconcile/3`, `:160-175` `report/2`, `--dump`).
  Маркеры — только в `fixtures/consumer/scenarios/*.ex`; `lib/` собирается без предупреждений.
- Корректная часть: `lib/consumer/domain/sales/account.ex:69-76` (`destroyable: true` — единственный
  в фикстуре), `account/profile.ex` (ручной `defstruct` + `Profile.Codec` с `union:`/`set:`/`map:`),
  `account/card.ex` + `card/codec.ex` (dump-only), `account/event/renamed.ex` (Payload по полям),
  `account/event/opened.ex` (ручной плагин нагрузки), `grants/event/*` (`union:`, `set:`/`map:`,
  `Es.ValueChanged`), `activity/projection.ex` (проекция с `KeyDestroyed`).
- Синтетический сценарий «шаги маршрута с получателем/контентом» — новый агрегат в
  `lib/consumer/domain/sales/<agg>/` плюс `exports` `lib/consumer/domain/sales.ex`.

## 7. Точки правки доков и сводов (тикеты 10/11)

- `docs/rules/11-domain.md` — `348` «Codec», `462` «Плагин по полям», `603` «Варианты семейства»,
  `672` «Dump/load только через фасад», `703` «Структура по полям» (`wire:`/`subject:` `:726`,
  `optional:` `:730-745`, `destroyable:` `:748-755`, `events:` `:757+`, `default:` `:765`),
  `832` «Event-sourced», `968` «Команда» (`:978-985`), `1048` «Es.Event»,
  `1121` «Нагрузка по полям» (`subject:` `:1141-1153`), `1156` «Нагрузка-Prim и `Es.ValueChanged`»,
  `1168` «Нагрузка-сущность», `1189`/`1227` «Подписи», `1426` «Сведения события», `1578` «Ратчет полноты».
- `docs/rules/23-personal-data.md` — `23` «Разметка», `65` «Поле нагрузки (`subject:`)» (`:87-91`
  единица шифротекста, `:104-117` CompileError, `:123-131` Inspect/редакция, `:133` `__es_subjects__/0`),
  `134` «Форма в хранении и доставке», `192` «Уничтоженное ПДн-значение» (`:196-201` формы,
  `:222-232` evolve/decide/project, `:228-233` `destroyable:`, `:257-265` ошибки load),
  `270` «Состояние в памяти», `292` «Хранилище ключей», `452` «Уничтожение ключа», `512` «Подписчик»,
  `552` «Чек-лист», `574` «Связанные правила».
- `docs/rules/14-events-outbox.md` — `90` «Aggregate → Outbox.Record» (маркер `:148-153`), `168`
  «Совместимость событий», `235` «Golden-фикстуры».
- `docs/rules/19-testing.md` — `8` case-модули, `78` round-trip, `132` совместимость, `193` агрегат,
  `306` проекции.
- `docs/rules/22-projections.md` — `10` объявление, `116` персональные данные, `349` версия/пересборка.
- `docs/rules/21-observability.md` — `:226`, `:241-243`, `:262`, `:280`.
- `docs/rules/12-errors.md` — `:92-100`; `docs/rules/13-repos.md` — `120` View, `806` снапшоты,
  `866` резервы, `1130` хранилище, `1253` состояние на версии.
- `docs/rules/20-agreements.md` — `602` опции `use`, `300` типы, `342` форма результата, `435` struct.
- `docs/rules/app/*.md` — ярус потребителя (`app/11-domain`, `app/13-repos`, `app/14-events-outbox`,
  `app/23-personal-data`), правится тем же коммитом.
- `CONTEXT.md` — `108` «Codec-плагин по полям», `114` «Спека полей», `119` «Структура по полям»,
  `146` «Семейство (union)», `585` «Семейство событий», `694-750` «Персональные данные» (`701`, `713`, `739`).
- ADR: 0056, 0073, 0074, 0075, 0076, 0078, 0090, 0091, 0092; нужен новый ADR.

## 8. Сборка и проверка

| Команда | Что проверяет | Длительность |
|---|---|---|
| `make boundary-check` | библиотека не знает потребителя | ~1 с |
| `make rules-check` | оба яруса `docs/rules` | ~1 с |
| `make layout-check` | разделители `# ---` / `# ===== … =====` | ~1 с |
| `make spec-check` | форма результата через `Core.Result` | ~1 с |
| `make format-check` | `mix format --check-formatted` | ~10 с |
| `make compile` | `mix compile --warnings-as-errors` | ~10-30 с |
| `make compile-no-optional` | сборка без optional-клиентов брокеров | ~40-90 с |
| `make consumer-check` | фикстура: boundary+spec lint, `check.exs` | ~40-120 с |
| `make deps-clean` / `make xref` | неиспользуемые deps / циклы компиляции | ~5-20 с |
| `make dialyzer` | PLT (с нуля — минуты) | ~40-90 с |
| `make test` | `mix test` (`:rabbit_stream`/`:kafka` исключены) | ~50 с |
| `make credo` | `mix credo --strict` + consumer | ~10-25 с |
| `make audit` | `mix deps.audit`, `mix hex.audit` | ~10 с |

- Один файл: `mix test test/core/struct_test.exs`; строка: `mix test path:42`.
- Отказы: `boundary-check` — `<path>:<line>: <текст>` + итог; `consumer-check` — `нет предупреждения:`/
  `лишнее:` + итог FAIL; `xref` — циклы (принят один: `Core.Es.Personal.Event`, ADR-0084);
  `compile --warnings-as-errors` — первое предупреждение становится ошибкой.
