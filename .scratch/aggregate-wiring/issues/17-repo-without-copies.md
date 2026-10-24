# 17: Репозиторий без `id:` / `aggregate:`

**What to build:** автор репозитория объявляет `use Core.Es.Aggregate.Repo` одной опцией `aggregate:`, а
`use Core.Es.Aggregate.Repo.Pg` — без `aggregate:` / `id:`: реализация берёт их из своего behaviour. Чужой ID в
`get` / `get_decision` / `append` / `refresh` / `page_stream` по-прежнему даёт предупреждение сборки. Старая форма —
`CompileError` с недостающими и неизвестными опциями. Спека — `../spec.md`, «`Core.Es.Aggregate.Repo`»,
«`Core.Es.Aggregate.Repo.Pg`», «Порядок работ», срез 3; ADR-0084. Образец — `prototype/repo-wiring`.

**Blocked by:** 16.

**Status:** resolved

- [x] `Es.Aggregate.Repo`: обязательна только `aggregate:` (`exports: [__es_event_codec__: 0]`); `id` — из кодека
  агрегата, без новой загрузки. `@callback`, `__es_aggregate_repo__/0` и функции-проверки `evolve/2` прежние.
- [x] `Es.Aggregate.Repo.Pg`: обязательны `behaviour:`, `errors:`, `outbox:`, опциональные прежние; `%{aggregate, id}`
  и головы `%Id{}` / `%Agg{}` — из `behaviour.__es_aggregate_repo__()`. Вызов `ensure_aggregate_id!` ушёл,
  `ensure_family_aggregate!` — против агрегата behaviour.
- [x] Все `use` репозиториев в `lib/`, `test/`, фикстуре переведены.
- [x] Тесты сверок `id:` / `aggregate:` в `Repo.Pg` удалены; старая форма опций — одно сообщение.
- [x] `make consumer-check`: сценарий `repo.ex` (чужой ID в функциях `Repo.Pg`) даёт те же предупреждения.
- [x] `@moduledoc` `Core.Es.Aggregate.Repo`, `Core.Es.Aggregate.Repo.Pg`.
- [x] Свод `13-repos.md` («Write event-sourced агрегата», «Снапшоты», «DI»: примеры без `id:` / `aggregate:`).
  `make rules-check`.
- [x] CHANGELOG: строки `use Core.Es.Aggregate.Repo`, `use Core.Es.Aggregate.Repo.Pg`; строка 3 «Версии библиотеки».
- [ ] С тикетом 18 конфликт в `Es.Aggregate.Repo.Pg` (опции и `declarations!`): вливаемый вторым перестраивается на
  первый.
- [x] Приёмка: `make` целиком.
- [ ] После влития удаляется ветка `prototype/repo-wiring`.

## Comments

- Ветка `prototype/repo-wiring` не удалена: её удаляет оркестратор после влития.
- Конфликт с тикетом 18 — у вливаемого вторым. В `Es.Aggregate.Repo.Pg` правка ограничена опциями,
  `validate_opts!` и `behaviour!/1`: вызов `KeyReservation.declarations!` и `checks/3` не тронут, `id`
  в него идёт из `behaviour.__es_aggregate_repo__()`. Абзацы moduledoc и свода о сверках ключа
  (`id:` модуля ключа — `id:` репозитория) оставлены тикету 18; пример `key_reservations:` в
  «Резервы ключей» `13-repos.md` переведён (сняты `aggregate:` / `id:` у `use Core.Es.Aggregate.Repo.Pg`).
- Сверка `ensure_behaviour_aggregate!` (`aggregate:` / `id:` реализации против behaviour) удалена
  вместе с опциями; её тест в `pg_test.exs` удалён. Пункт CHANGELOG «Рассогласованные `id:` /
  `aggregate:` у behaviour и реализации…» (тот же «Не выпущено») переписан: остался только переход
  `behaviour:` на `use Core.Es.Aggregate.Repo` — сверять копии больше нечего.
- Экспорт `fold/2` у агрегата `Repo.Pg` больше не проверяет: агрегат приходит из behaviour, где
  `aggregate:` уже проверен на `__es_event_codec__/0`.
- `make consumer-check`: 127 ожидаемых предупреждений, лишних нет; маркеры сценариев не менялись.
