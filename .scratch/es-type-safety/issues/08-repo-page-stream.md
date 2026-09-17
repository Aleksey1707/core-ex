# 08: `page_stream/4` у репозиториев агрегатов обоих видов

**What to build:** автор читающего usecase читает страницу потока вызовом
`@repo.page_stream(id, limit, offset, context)` репозитория агрегата — event-sourced или state-stored. ID другого агрегата ловится при сборке, а не даёт молча пустую
страницу. Исходы страницы потока прежние.

**Blocked by:** 01

**Status:** ready-for-agent

**Spec:** [Типобезопасность потребителя `Core.Es`](../spec.md) — «Репозиторий event-sourced агрегата»; «Further Notes»
— почему и у state-stored

- [ ] Колбэк `page_stream/4` в `use Core.Es.Aggregate.Repo`; генерация в `Core.Es.Aggregate.Repo.Pg` и в
      `Core.Repo.Pg.StateStored` с `event_codec:`. Голова — закрытый struct ID агрегата, кодек — свой; результат сужен в
      `generated: true`.
- [ ] Исходы — как у нынешней страницы потока: порядок по `aggregate_version`, `count` — весь поток, пустой поток —
      страница с `count: 0`, первая ошибка загрузки — `{:error, _}` на всю страницу.
- [ ] `Core.Es.Store.page_stream/5` — `@doc false` реализация.
- [ ] Фикстура: маркер X3 (ID другого агрегата); чтение страницы потока в usecase — ноль предупреждений.
- [ ] ExUnit: страница потока через `page_stream/4` у репозитория event-sourced агрегата и у state-stored; прежние
      тесты `Store.page_stream/5` переведены или оставлены тестами реализации.
- [ ] Свод: `13-repos.md` («Страница потока», хранилище событий); ярус `app/`: `13-repos.md`, `14-events-outbox.md`,
      `00-index.md` (строка карты «`Core.Es.Store.page_stream/5` → `@repo.page_stream/4`»); описание скилла `repos`.
- [ ] moduledoc `Core.Es.Aggregate.Repo`, `Core.Es.Aggregate.Repo.Pg`, `Core.Repo.Pg.StateStored`, `Core.Es.Store`.
- [ ] `CHANGELOG.md`, «Не выпущено»: пункт хранилища событий / страницы потока дополнен, «было → стало».
- [ ] `make` зелёный.
