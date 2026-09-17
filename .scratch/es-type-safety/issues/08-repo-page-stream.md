# 08: `page_stream/4` у репозиториев агрегатов обоих видов

**What to build:** автор читающего usecase читает страницу потока вызовом
`@repo.page_stream(id, limit, offset, context)` репозитория агрегата — event-sourced или state-stored. ID другого агрегата ловится при сборке, а не даёт молча пустую
страницу. Исходы страницы потока прежние.

**Blocked by:** 01

**Status:** resolved

**Spec:** [Типобезопасность потребителя `Core.Es`](../spec.md) — «Репозиторий event-sourced агрегата»; «Further Notes»
— почему и у state-stored

- [x] Колбэк `page_stream/4` в `use Core.Es.Aggregate.Repo`; генерация в `Core.Es.Aggregate.Repo.Pg` и в
      `Core.Repo.Pg.StateStored` с `event_codec:`. Голова — закрытый struct ID агрегата, кодек — свой; результат сужен в
      `generated: true`.
- [x] Исходы — как у нынешней страницы потока: порядок по `aggregate_version`, `count` — весь поток, пустой поток —
      страница с `count: 0`, первая ошибка загрузки — `{:error, _}` на всю страницу.
- [x] `Core.Es.Store.page_stream/5` — `@doc false` реализация.
- [x] Фикстура: маркер X3 (ID другого агрегата); чтение страницы потока в usecase — ноль предупреждений.
- [x] ExUnit: страница потока через `page_stream/4` у репозитория event-sourced агрегата и у state-stored; прежние
      тесты `Store.page_stream/5` переведены или оставлены тестами реализации.
- [x] Свод: `13-repos.md` («Страница потока», хранилище событий); ярус `app/`: `13-repos.md`, `14-events-outbox.md`,
      `00-index.md` (строка карты «`Core.Es.Store.page_stream/5` → `@repo.page_stream/4`»); описание скилла `repos`.
- [x] moduledoc `Core.Es.Aggregate.Repo`, `Core.Es.Aggregate.Repo.Pg`, `Core.Repo.Pg.StateStored`, `Core.Es.Store`.
- [x] `CHANGELOG.md`, «Не выпущено»: пункт хранилища событий / страницы потока дополнен, «было → стало».
- [x] `make` зелёный.

## Comments

- 2026-09-17 — реализация:
  - `use Core.Es.Aggregate.Repo` объявляет колбэк `page_stream/4` (`callbacks/0` — пятым, `behaviour:` без него —
    `CompileError`); `use Core.Es.Aggregate.Repo.Pg` генерирует её под `@impl true`, `use Core.Repo.Pg.StateStored` —
    отдельным `quote generated: true` с `@doc` и `@spec` (колбэка в `use Core.Repo` нет, функция — по `event_codec:`).
    Голова — `%<id:>{}`, `%Limit{}`, `%Offset{}`, `%Context{}`; результат `Core.Es.Store.page_stream/5` сужен до
    `{:ok, %Core.Pagination.Result{} = page} | {:error, reason}`; функция `defoverridable`. DAO и фасад — прежние,
    `Core.Config` (опции `repo:` / `codec:` event-sourced репозитория на страницу не действуют — записано в moduledoc);
  - `Core.Es.Store.page_stream/5` — `@doc false`, сигнатура прежняя; её тесты (`store_test.exs`) оставлены тестами
    реализации: другой тип агрегата с тем же `aggregate_id`, неизвестный тег, offset за концом;
  - ExUnit: контракт `Core.EsAggregateRepoContract` — describe `page_stream` (порядок и `count`, пустой поток, ошибка
    всей страницы), прогоняется на `Account.Repo.Pg` и `Snapshotted`; `state_stored_test.exs` — поток с разрывами и
    агрегат без событий; `RacyRepo.Pg` делегирует `page_stream/4`;
  - фикстура: `Consumer.Usecase.history/4` на `@repo.page_stream/4` с разбором результата — ноль предупреждений;
    `lib/scenarios/repo.ex` — X3 (ID другого агрегата), X3b (`:ok` по результату), X3c (опечатка `page.cout`).
    Маркеров 92 (было 89). Мутации: без сужения гаснут X3b и X3c, голова `%_{}` гасит X3;
  - state-stored в фикстуре нет (тикет 10): временный state-stored модуль в фикстуре — ID другого агрегата и
    опечатка в поле страницы ловятся, лишних предупреждений нет; модуль удалён;
  - сверх перечня: `13-repos.md` — «Write state-stored агрегата» (генерируемая `page_stream/4`), таблица и
    сужение в «Write event-sourced агрегата»; `CHANGELOG.md` — пункты «Чтение потока» (перенос `Event.Repo`),
    «Write-репозиторий event-sourced агрегата» и «`Core.Repo.Pg.Es` → `Core.Repo.Pg.StateStored`» (занятое имя);
    в `app/00-index.md` строка `Event.Repo.page_by_aggregate/4` ведёт сразу к `@repo.page_stream/4`. ADR-0014 не
    правился — запись решения.
- 2026-09-17 — по ревью: `page_stream_ast/1` в `StateStored` — сразу под `validate_opts!/1`, берёт `cfg.id` /
  `cfg.event_codec` (без тёзки модуля и переменной `id`); `13-repos.md` — ветка `{:error, _}` в сигнатуре «Страницы
  потока», «нечитаемый поток — исключение» только у `get` / `get_many` / `refresh`, «Проверяется:» — у репозитория
  event-sourced агрегата (state-stored в фикстуре — тикет 10); moduledoc `Es.Aggregate.Repo.Pg` — то же про нечитаемый
  поток, `repo:` / `codec:` описаны как опции восстановления состояния; `app/14-events-outbox.md` — запрет прямого
  `Store.page_stream/5` снят (дублировал `13-repos.md`); `app/00-index.md` — обе строки страницы потока ссылаются на
  `13-repos.md` яруса. Не принято: «было → стало» для невыпущенной `page_stream/5` в CHANGELOG и строка карты — их
  требует тикет, прецедент `await/4`; коды X3b / X3c — как G4b / G4c прошлого среза; общий построитель AST для двух
  `page_stream` — головы различаются `@impl` / `@spec`, общий модуль ради восьми строк не заведён; `opts` у
  `page_stream/4` и опции `repo:` / `codec:` на странице потока — сигнатура из спеки, `Store.page_stream/5` читает
  через `Core.Config`, как и `Store.append/5`; тест ошибки всей страницы у state-stored — реализация общая, исход
  держат контракт и `store_test.exs`.
