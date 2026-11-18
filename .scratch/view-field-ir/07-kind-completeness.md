Status: resolved

# 07: Полнота вида проверяется на сборке

**What to build:** каждый switch по виду поля, который обязан знать весь allowlist хоста, сверяется
с `Core.Field.Spec.kinds(host)` на сборке. Срез 1: `Core.View.shape/2`,
`Core.Field.spec_type/4` и `Core.Codec.Plugin.Redump.field_spec/1`; существующие проверки
`View.Field.check_kinds!/1` и `Fields.Kind` переводятся на общий helper. Новый вид без операции
даёт `CompileError` с именем вида, а не `FunctionClauseError` и не тихое значение в `new/1`.

## Problem Statement

Явные проверки полноты есть только у `Core.View.Field.@projections` и
`Core.Codec.Plugin.Fields.Kind.@adapters`. Остальные switch'и по виду не сверяются ни с allowlist
хоста, ни между собой: `Field.spec_type/4` и `Redump.field_spec/1` падают `FunctionClauseError` в
момент сборки чужого модуля, а `Core.View.shape/2` имеет catch-all и молча не приводит значение
нового вида с `shape?: true`. Правка `Spec.@host_kinds` не заставляет обновить эти места.

## Решения

- **Одна проверка набора.** `Core.Field.Spec.check_kinds!(host, handled, extras, where)`
  сравнивает `handled` с `kinds(host) ++ extras` в обе стороны. Текст — `CompileError` с
  `where`, списком отсутствующих видов и списком видов вне allowlist.
- **Тексты хостов сохраняются.** `View.Field.check_kinds!/1` и `Fields.Kind` продолжают
  форматировать свои отказы для отсутствующей строки/операции; общий helper добавляет проверку
  лишних видов. `View.Field.check_kinds!([:missing])` по-прежнему даёт
  «View: вид missing: нет всех проекций».
- **`View.shape` — флаги + табличный тест.** `View.Field.shape_kinds/0` явно перечисляет виды,
  у которых есть клауза `Core.View.shape/2` (`prim`, `enum`, `list`, `set`, `map`).
  `check_kinds!/1` проверяет: все `shape? != false` виды входят в `shape_kinds`; `shape_kinds`
  входят в allowlist View. Тест `view/field_test.exs` вызывает `Core.View.shape/2` для каждого
  вида из `shape_kinds/0`. `View.shape/2` из таблицы не генерируется (OOS
  `view-kind-single-module.md`).
- **`spec_type`** проверяется против `kinds(:struct)` (набор тот же у `Struct`, `Payload` и
  `ValueChanged`); **`Redump.field_spec`** — против `kinds(:plugin)`.
- **Вне тикета (срез 2):** `Field.walk_places/4`, `Struct.check_value!/3`,
  `Labels.Details.shape/1`, `Labels.Walk.data/3`, `Kind.type_guard/2` и host-extra `text:`
  подписей.
- **CHANGELOG не меняется:** проверки внутренние. ADR-0097/0056 и OOS
  `field-spec-shared-normalizer.md` не пересматриваются; таблицы видов не сливаются.

## Тесты

- `test/core/field/spec_test.exs`: helper — ok, missing, extra, extras (host-специфичный вид).
- `test/core/view/field_test.exs`: таблица `shape_kinds/0` — каждый вид приводит значение
  ожидаемой формы; существующий «вид × проекция» остаётся.
- `View.Field.check_kinds!([:missing])` — прежний текст.
- `Fields.Kind`, `spec_type`, `Redump` проверяются сборкой; негативных тестов на compile-time
  вызовы нет (allowlist не подменяется в тесте).
- `make consumer-check`, полный `mix test`, `mix credo --strict`, `mix dialyzer`.

## Acceptance

- [x] `Spec.check_kinds!/4` сравнивает наборы в обе стороны и называет missing/extra.
- [x] `View.Field.shape_kinds/0` + проверка флагов + табличный тест `Core.View.shape/2`.
- [x] `Core.Field.spec_type/4` и `Redump.field_spec/1` имеют compile-time проверку allowlist.
- [x] `View.Field` и `Fields.Kind` используют общий helper; тексты прежние.
- [x] `make consumer-check`, `mix test`, `mix credo --strict`, `mix dialyzer` зелёные.

## Сделано

- `lib/core/field/spec.ex`: `check_kinds!/4` — сравнение в обе стороны, `gaps_text/2` с
  missing/extra; вызовы обязательные, без default-арностей.
- `lib/core/view/field.ex`: `shape_kinds/0` (`prim`, `enum`, `list`, `set`, `map`),
  `check_projections!/1` и `check_shape!/1` разделены; `check_kinds!/1` делегирует набор в
  общий helper.
- `lib/core/field.ex`, `lib/core/codec/plugin/redump.ex`: compile-time сверка `spec_type/4` и
  `field_spec/1` с `kinds(:struct)`/`kinds(:plugin)`.
- `lib/core/codec/plugin/fields/kind.ex`: проверка набора адаптеров через общий helper.
- Тесты: helper (ok/missing/extra/extras), `shape_kinds` с невакциозными значениями
  (`@hex → @uuid`); прежний текст `check_kinds!([:missing])` сохранён.

Замечания code-review применены: разделение проверок формы, `where` обязателен, текст
«нет обработки», `@label` в `Redump`, невакциозный тест.

Проверка: `make format-check boundary-check spec-check layout-check rules-check xref
consumer-check` — зелёные; `mix credo --strict`, `mix dialyzer` — без замечаний; `mix test` —
3511 passed, 10 excluded.

## Остаточный риск

`@typespec_kinds` и `@field_spec_kinds` — ручные копии allowlist. Проверка ловит новый вид,
добавленный в `Spec.@base_kinds`, но не удаление клаузы `spec_type`/`field_spec` при неизменном
списке; это ловится только табличным тестом поведения, которого в срезе 1 нет. Срез 2
(`walk_places`, `Struct.check_value!`, `Labels.Details/Walk`, `type_guard`, `text:`) остаётся
отдельным кандидатом.
