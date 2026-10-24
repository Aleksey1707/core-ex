# 08: Нарезка срезов перевода и их порядок

Type: grilling
Status: resolved

Blocked by: 07

## Question

На какие срезы делится перевод builder'ов `lib/` на канонический режим и в каком порядке они идут после срезов
aggregate-wiring (`.scratch/aggregate-wiring/spec.md`)?

Уже решено и в нарезку входит как ограничение:

- первый срез — `Helper.Opts` (`expand!` / `literal!` / value-варианты, `reject!/2`) и `CredoChecks.UseOpts` с
  храповиком `files: %{excluded: …}`; последующие срезы снимают свои модули с храповика;
- `Core.Prim`, `Prim.Wrapper` и семь обёрток — один срез, без переходного режима;
- `Repo.Pg` и `StateStored` — один срез;
- срез `Es.Event` (`payload:` — проверка в теле) — после тикета-бага
  `.scratch/es-event-nested-payload/issues/01-check-subject-silent-skip.md`;
- builder'ы aggregate-wiring (`Es.Event.Codec`, `Outbox`, `Repo`, `Repo.Pg`, `KeyReservation`, `Projection`) —
  после соответствующих срезов aggregate-wiring, в них не вливаются.

Решить: группировку остальных builder'ов по `inventory.md` (режим «тело», смешанные, case-модули, внутренние
вложенные `use`), критерий размера среза, где идут пункты CHANGELOG «Ломающие изменения контракта»
(`Es.Projection` `name:` / `events:` / `version:` / `personal:`, `Es.Event.TagsCase` `except_*`), и как каждый срез
проверяется (`make consumer-check`, xref).

## Answer

Срез — группа builder'ов с общим кодом разбора (общий `*.Opts`, общие `where` / `reject!`, композиция вложенным
`use`); группы с одинаковым прологом, которые иначе делить незачем, объединяются. Число строк — не критерий. После
каждого среза `make` зелёный.

Порядок относительно aggregate-wiring (AW, `.scratch/aggregate-wiring/spec.md`, «Порядок работ»): ждёт только тот срез,
что правит файл AW-среза. S1 — после AW-1 (оба правят `lib/core/helper/opts.ex`); builder'ы вне AW — сразу после S1,
параллельно, независимо от AW-2…5; конфликт между ними — только в списке храповика `.credo.exs`.

| Срез | Builder'ы | Ждёт |
|---|---|---|
| S1 — инструмент и «раскрытие» | `Helper.Opts` (`expand!` / `literal!` / value-варианты / `reject!/2`), `CredoChecks.UseOpts` с храповиком `files: %{excluded: …}`, `credo:disable` у `DAO`; перевод пролога `Es.Aggregate`, `Es.Aggregate.Process`, `Es.Cmd`, `Core.Repo`, `Repo.Pg.Schema`, `View`, шести case-модулей (`Enum.DocsCase`, `Es.EventCompatCase`, `Es.ProjectionCase`, `Es.Personal.KeyStoreCase`, `Labels.CompletenessCase`, `Repo.ConstraintErrorsCase`) | AW-1 |
| Prim | `Core.Prim`, `Prim.Wrapper`, семь обёрток, `Prim.Opts` | S1 |
| Labels | `Labels.Event` / `.ID` / `.Values` / `.Text` / `.Fields`, `Web.Event` | S1 |
| Тело-мелкие | `Enum`, `Context.Accessor`, `Es.ValueChanged` | S1 |
| Codec | `Codec`, `Codec.Facade`, `Codec.Plugin`; строка `union: unquote(family)` вложенного `use` в `Es.Event.Codec` | S1, AW-2 |
| Repo.Pg | `Repo.Pg`, `Repo.Pg.StateStored` | S1, AW-2 |
| Es-событие | `Es.Event` (`payload:` — проверка в теле), `Es.Event.Payload` | S1, AW-2, тикет-баг `check_subject!` |
| Es-кодек | `Es.Event.Codec` (`tags:` / `upcasts:`), `Es.Outbox`, `Es.Event.TagsCase` | S1, AW-2, Codec |
| Es-репозиторий | `Es.Aggregate.Repo`, `Es.Aggregate.Repo.Pg`, `Es.KeyReservation` | S1, AW-3, AW-4 |
| Проекция | `Es.Projection` | S1, AW-5 |

- В S1 группа «раскрытие» вне AW меняет только пролог (`Macro.expand_literals` → `expand!` + `literal!`) и тексты через
  `reject!`: API получает первых пользователей, храповик стартует короче. Case-модули AW не задевает.
- `Es.Event.Payload` — со срезом `Es.Event`: проверка `payload:` читает его интроспекцию. `TagsCase` — с кодеком, а не
  с case-модулями S1: он смешанный и ломающий.

CHANGELOG — один накопительный пункт «Ломающие изменения контракта»: «опции `use` — только литералом, кроме
объявленных выражений», с таблицей «builder → опции, принимающие выражение». Ломка шире `Es.Projection` и `TagsCase`:
каждая опция-литерал builder'а режима «тело» раньше принимала атрибут (`values: @values` у `Enum`). Пункт заводит
первый вливаемый срез, который ломает контракт; каждый следующий дописывает свою строку. Правка потребителя: атрибут
или выражение → литерал в вызове.

Приёмка каждого среза (в спеке):

- `make` целиком;
- `consumer-check` без новых предупреждений фикстуры-потребителя;
- `mix xref graph --label compile` фикстуры не изменился, у библиотеки compile-рёбра только уходят;
- храповик сужен на модули среза; срез, влитый последним, удаляет список `excluded`;
- тесты builder'а: опечатка в ключе, нелитерал в опции-литерале, неверное выражение — ошибка в своём месте (при
  раскрытии / в теле) и с меткой builder'а.

Расхождение свода и кода на время перевода в `docs/rules/DEBT.md` не пишется: DEBT — «осознанно не чинится», а здесь
идёт перевод. Запись о расхождении — сам список `excluded` храповика.

## Comments

- Из «Текст правила, форма ADR и спека»: накопительный пункт CHANGELOG идёт в раздел «Изменения контракта макросов»,
  а не «Ломающие изменения контракта». По `CLAUDE.md` опции `use` относятся туда.
