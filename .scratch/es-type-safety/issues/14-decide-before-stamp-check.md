# 14: Сверка `by` / `at` команды до вызова `decide/2`

**What to build:** команда без `by` / `at` отсеивается **до** пользовательского `decide/2`, как было
до перевода `execute/2` на `apply_decision/4`: либо проверка в генерируемом `execute/2` перед
вызовом `decide`, либо `FunctionClauseError` в нём же по паттерну `%{by: _, at: _}`.

**Status:** needs-triage

**Spec:** [Типобезопасность потребителя `Core.Es`](../spec.md) — «Агрегат — `Core.Es.Aggregate`»

- [ ] отсев команды без `by` / `at` до `decide/2`; тест на исход и на то, что `decide` не звался

## Comments

> *Найдено в code-review ветки `develop` (18.09.2026). Утверждения проверены по `git show`.*

## Triage Notes

**Что установлено:**

- Было (до `87b2579`): `Core.Es.Aggregate.execute(aggregate, state, %{by: by, at: at} = command)`
  звал `aggregate.decide/2` в теле — команда без `by` / `at` давала `FunctionClauseError` на
  границе библиотеки, `decide/2` не исполнялся.
- Стало: `apply_decision(__MODULE__, state, command, decide(command, state))`
  (`lib/core/es/aggregate.ex:131`). Аргумент вычисляется первым, поэтому `decide/2` отрабатывает
  на команде, которую `apply_decision/4` всё равно отвергнет своей головой
  `%{by: by, at: at} = command` (`lib/core/es/aggregate.ex:165`).
- Переход был осознанным: спек требует «библиотека сама `aggregate.decide` больше не зовёт» — это
  и есть граница типов ADR-0014. Порядок проверок в спеке не оговорён.
- Голова генерируемого `execute/2` закрывает только `%__MODULE__{}` состояния и `is_struct(command)`
  (`Core.Es.Aggregate.Process.execute` — тоже `is_struct(command)`), так что команда без штампа
  достижима: `use Core.Es.Cmd` держит `by` / `at` в `@enforce_keys`, но struct мимо билдера — нет.
- Цена сейчас: `decide/2` потребителя исполняется на заведомо негодной команде. По контракту он
  чистый (`11-domain.md`), так что записи это не портит; страдает диагностика — если `decide/2` сам
  падает на такой команде, причина «в команде нет `by` / `at`» в стектрейсе не видна.

**Что нужно решить:**

- Чинить ли вообще: это ошибка программиста, оба варианта падают, разница — в тексте падения.
- Если чинить — где: `when is_map_key(command, :by) and is_map_key(command, :at)` в голове
  генерируемого `execute/2` (граница остаётся у потребителя, но guard в `quote` шумит) или
  явный отсев в теле до `decide`.
- Не ломает ли guard вывод типов у потребителя (ADR-0014): голова `execute/2` — та самая граница,
  где `is_struct/2` уже отвергли в пользу `%__MODULE__{}`.
