# Ревью декларативных билдеров DTO и агрегатов

Type: review
Status: needs-triage

Ревью архитектуры от 2026-10-22: Codec, Prim, Enum, View, Labels, Web.Event, Es.Aggregate, Es.Event, Repo.
Ищем возможности углубления: shallow-модули, утечки через seam, дублирование машинерии между билдерами.
Словарь — `codebase-design` (module, interface, depth, seam, adapter, leverage, locality), домен — `CONTEXT.md`.

Кандидат 1 «Поле спеки — свой module, а не 6-кортеж» проработан, у него есть спек и тикеты:
`.scratch/codec-field/`. Остальные кандидаты — находки без решений, по файлу в `issues/`. Каждый
прорабатывается отдельной сессией: обсуждение с вопросами → `/to-spec` → `/to-tickets`.

Строки в файлах кандидатов указаны на момент ревью и примерные — перед проработкой их нужно перепроверить.

## Кандидаты и очередь

| Очередь | Файл | Кандидат | Сила | Контракт потребителя |
|---|---|---|---|---|
| 1 | `01-prim-leaf-kind.md` | Prim сам отдаёт leaf и kind | Strong | не меняется |
| 2 | `02-event-write-path.md` | Запись событий агрегата — один module | Strong | не меняется |
| 3 | `03-labels-read-side.md` | Чтение подписей: одна классификация и один обход | Strong | не меняется |
| 4 | `04-prim-wrapper-protocol.md` | Prim-обёртки: общий протокол в одном месте | Strong | не меняется |
| 5 | `05-web-event-schema.md` | Web.Event: схема функциями, поля одним списком | Strong | не меняется |
| 6 | `06-labels-foreign-declarations.md` | Labels: явный interface чтения чужих объявлений | Worth exploring | не меняется |
| 7 | `07-aggregate-wiring.md` | Связи агрегата вычисляются один раз | Strong | ломается |
| 7 | `13-aggregate-wiring-checks.md` | Сверка `id:` / `aggregate:` репозитория (из 07) | Strong | не меняется |
| 7 | `08-event-family-id-by.md` | Событие: `aggregate_id`/`by` на семейство | Worth exploring | ломается |
| 7 | `14-event-template-one-branch.md` | Шаблон события: одна ветка `quote` (из 08) | Worth exploring | не меняется |
| 8 | `09-facade-es-knowledge.md` | Фасад Codec перестаёт знать про события | Worth exploring | не меняется |
| 8 | `10-key-reservation-completeness.md` | Полнота `reservation/1` — в модуле ключа | Worth exploring | не меняется |
| — | `11-field-spec-shared-syntax.md` | Общий синтаксис спеки для View и плагина — wontfix | Worth exploring | не меняется |
| — | `15-field-check-shared-rules.md` | Общие правила спеки полей в одном месте (из 11) | Worth exploring | не меняется |
| — | `12-speculative.md` | View по kind, режимы разбора опций, рефлексия redump — разнесён | Speculative | — |
| — | `16-es-cmd-marker.md` | `Es.Cmd`: снять маркер `__es_cmd__/0` (из 12) | Strong | не меняется |
| — | `17-use-opts-parsing-mode.md` | Опции `use`: один режим разбора (из 12) | Worth exploring | решается |
| — | `18-plugin-manual-clauses-module.md` | Разбор ручных клауз плагина — свой module (из 12) | Speculative | не меняется |

Зависимости:
- 03 опирается на 01 и на `.scratch/codec-field/` (struct поля).
- 06 лучше делать после 03.
- 07 и 08 пересекаются: их обсуждают вместе, а ломающие изменения идут одним выпуском. Карта: `.scratch/aggregate-wiring/map.md` (поглотила и 10). Карта завершена: спек `.scratch/aggregate-wiring/spec.md`.
- 15 — после 01.
- 17 — после 07 и 14.

## Смотрел, трения нет

- `Core.Es.Aggregate` (`fold` / `execute` / `apply_decision`) — deep module, тонкий quote по форме ADR-0014.
- `Core.Es.Check` — один механизм полноты на три билдера и фасад.
- `Process` / `Execution` / `Server` — разделение оправдано, `Server` тестируется отдельно.
- Путь чтения `Es.Aggregate.Repo.Pg` вместе со `Snapshot` — около 1050 строк за шестью функциями.
- `Core.Codec.Redump.run/3`, `Core.Web.Response` и `Response.Schema`, `Core.Helper.Opts`, `Core.Helper.Keys`.
- Конвейер `Core.Prim` (`run_*`, `normalize_*`), `Core.Enum`, каркас `Codec.Plugin.__using__`.
- Дробление Labels на 10 файлов со стороны объявлений (ADR-0063).
- Открытые головы `Repo.Pg` / `StateStored` и bang через `unwrap!` уже записаны в `docs/rules/DEBT.md`.
