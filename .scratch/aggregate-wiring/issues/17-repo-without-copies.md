# 17: Репозиторий без `id:` / `aggregate:`

**What to build:** автор репозитория объявляет `use Core.Es.Aggregate.Repo` одной опцией `aggregate:`, а
`use Core.Es.Aggregate.Repo.Pg` — без `aggregate:` / `id:`: реализация берёт их из своего behaviour. Чужой ID в
`get` / `get_decision` / `append` / `refresh` / `page_stream` по-прежнему даёт предупреждение сборки. Старая форма —
`CompileError` с недостающими и неизвестными опциями. Спека — `../spec.md`, «`Core.Es.Aggregate.Repo`»,
«`Core.Es.Aggregate.Repo.Pg`», «Порядок работ», срез 3; ADR-0084. Образец — `prototype/repo-wiring`.

**Blocked by:** 16.

**Status:** ready-for-agent

- [ ] `Es.Aggregate.Repo`: обязательна только `aggregate:` (`exports: [__es_event_codec__: 0]`); `id` — из кодека
  агрегата, без новой загрузки. `@callback`, `__es_aggregate_repo__/0` и функции-проверки `evolve/2` прежние.
- [ ] `Es.Aggregate.Repo.Pg`: обязательны `behaviour:`, `errors:`, `outbox:`, опциональные прежние; `%{aggregate, id}`
  и головы `%Id{}` / `%Agg{}` — из `behaviour.__es_aggregate_repo__()`. Вызов `ensure_aggregate_id!` ушёл,
  `ensure_family_aggregate!` — против агрегата behaviour.
- [ ] Все `use` репозиториев в `lib/`, `test/`, фикстуре переведены.
- [ ] Тесты сверок `id:` / `aggregate:` в `Repo.Pg` удалены; старая форма опций — одно сообщение.
- [ ] `make consumer-check`: сценарий `repo.ex` (чужой ID в функциях `Repo.Pg`) даёт те же предупреждения.
- [ ] `@moduledoc` `Core.Es.Aggregate.Repo`, `Core.Es.Aggregate.Repo.Pg`.
- [ ] Свод `13-repos.md` («Write event-sourced агрегата», «Снапшоты», «DI»: примеры без `id:` / `aggregate:`).
  `make rules-check`.
- [ ] CHANGELOG: строки `use Core.Es.Aggregate.Repo`, `use Core.Es.Aggregate.Repo.Pg`; строка 3 «Версии библиотеки».
- [ ] С тикетом 18 конфликт в `Es.Aggregate.Repo.Pg` (опции и `declarations!`): вливаемый вторым перестраивается на
  первый.
- [ ] Приёмка: `make` целиком.
- [ ] После влития удаляется ветка `prototype/repo-wiring`.
