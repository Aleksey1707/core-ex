# Разбор опций `use`

Type: wayfinder:map

## Destination

Новый ADR «Разбор опций `use`», текст правки `docs/rules/20-agreements.md` («Параметры `__using__`… проверка на
этапе компиляции») и `.scratch/use-opts-parsing/spec.md` со срезами перевода по группам builder'ов, готовый к
`/to-tickets`. Кода в `lib/` в карте нет. Текст правила лежит в спеке, в свод его вносит первый срез вместе с API и
проверкой (уточнено тикетом «Текст правила, форма ADR и спека»).

Источник — тикет ревью «Опции `use` — один режим разбора» (`.scratch/builders-review/issues/17-use-opts-parsing-mode.md`).

## Notes

- Охват — все модули `lib/` с `__using__`: builder'ы потребителя, case-модули (`Labels.CompletenessCase`,
  `EventCompatCase`, `ProjectionCase` …) и внутренние (`Core.View.Dumper`, вложенный `use` в `Repo.Pg.StateStored`,
  `use Core.Codec.Plugin` из `Es.Event.Codec`).
- Контракт потребителя не ломается: опции-выражения (`name: first_line(@moduledoc)` — правило `11-domain.md` для
  каждого Prim, `tags: @tag_by_mod`, `upcasts: @upcasts`) остаются законными. Канонический режим ищется по опции, а
  не по builder'у. Нелитерал в опции, которой контракт его не разрешает (`Es.Projection` `name: @attr`), ломается
  пунктом CHANGELOG «Ломающие изменения контракта». Уточнено тикетом «Текст правила, форма ADR и спека»: раздел —
  «Изменения контракта макросов».
- Срезы aggregate-wiring (ADR-0084, `.scratch/aggregate-wiring/spec.md`) ещё не реализованы и меняют опции
  `Es.Event.Codec`, `Outbox`, `Repo`, `Repo.Pg`, `KeyReservation`, `Projection`. Срезы этой карты идут после них и в
  них не вливаются.
- Смена `bind_quoted` на `unquote` меняет генерируемый код и вывод типов у потребителя: проверяется
  `make consumer-check` на временной ветке, а не рассуждением (ADR-0014). Основное дерево `lib/` в карте не правится.
- Своды каждой сессии: `docs/rules/20-agreements.md` («Стиль кодирования», «Генерируемые функции»), skill
  `architecture` (компиляция без конфигурации потребителя), `Core.Helper.Opts`.
- О потребителях — только обезличенно («потребитель A»).

## Decisions so far

- [Опции `use` сейчас](issues/01-opts-inventory.md): шесть групп разбора (17 при раскрытии, 4 смешанных, 23 в теле, `DAO`
  особый); таблица — [`inventory.md`](inventory.md)
- [Канонический режим разбора и критерий исключения](issues/02-canonical-mode.md): режим по опции — ключи и
  опции-литералы при раскрытии, опции-выражения (`@expression_keys`) AST-ом в тело через `@doc false` `<key>!`;
  захват — выражение, опция-модуль — только литерал, `bind_quoted` MUST NOT
- [Прототип канонического режима на двух builder'ах](issues/03-mode-prototype.md): собирается без потерь у
  потребителя; литерал вычисляется и включает `-1`, проверки по вложенным модулям при раскрытии невозможны,
  `union:` — литерал, `Core.Prim` с семью обёртками — один срез
- [Ключи опций при композиции builder'ов](issues/04-composed-keys.md): композиция вложенным `use`, «кто отбрасывает
  ключи, тот их и проверяет»; проходные функции ключей уходят, остаётся протокол `Prim.Wrapper` (+ `expression_keys/0`)
- [Общие тексты `CompileError` опций](issues/05-compile-error-texts.md): `<метка>: <ключ>[: <элемент>]: <текст>` без
  модуля вызывающего, `raise` через `Helper.Opts.reject!/2` без `file:` / `line:`, хвост «ожидается …, получено …»
- [Механическая проверка канонического режима](issues/06-mode-lint.md): Credo-check `CredoChecks.UseOpts` только
  на `lib/` — `bind_quoted` в модуле с `__using__`, первое употребление `opts` через `expand!` / `prepare!`, функции
  ключей вне `Prim.Wrapper`; остальное ревью; храповик `files: %{excluded: …}` с первого среза
- [Проверки опции-литерала по другим модулям](issues/07-literal-module-checks.md): место — по опции; по умолчанию
  `module!` при раскрытии, в теле через `<key>!` — у опции с модулем, вложенным в вызывающего (`Codec.Plugin`
  `types:` / `fields:` / `variants:`, `Es.Event` `payload:`); громкий отказ везде, генерация — в месте `use`; дыра
  `check_subject!` — [тикет-баг](../es-event-nested-payload/issues/01-check-subject-silent-skip.md)
- [Нарезка срезов перевода и их порядок](issues/08-migration-slices.md): десять срезов по общему коду разбора; S1 —
  инструмент, храповик и пролог группы «раскрытие» вне AW, после AW-1; остальные ждут только свой AW-срез; один
  накопительный пункт CHANGELOG «только литералом, кроме выражений»; приёмка — `make`, `consumer-check`, xref, храповик

- [Текст правила, форма ADR и спека](issues/09-adr-rule-spec.md): записаны ADR-0085
  (`docs/adr/0085-use-opts-parsing.md`) и [спека](spec.md) (ready-for-agent); подраздел «Опции `use`» свода
  вносит S1 по тексту из спеки, пункт CHANGELOG — в «Изменения контракта макросов»

## Not yet specified

## Out of scope

- Ломка контракта ради единого режима «всё при раскрытии» (запрет опций через атрибут или выражение): правит каждый
  Prim у каждого потребителя.
- Состав опций шести builder'ов aggregate-wiring: решён ADR-0084.
- Длинный `quote` `Core.Repo.Pg`: записан в `docs/rules/DEBT.md`.
- Тексты и позиция ошибок в хуках `@before_compile` / `@after_compile`: проверки модуля, а не опции
  ([Общие тексты `CompileError` опций](issues/05-compile-error-texts.md)).
