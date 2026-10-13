# 02: Подписи внутри события — `labels: true`

**Status:** resolved

**Blocked by:** 01.

**What to build:** `use Core.Web.Event, labels: true` добавляет в событие страницы событий `title` и `details`.
Дамп сведений из `Core.Web.Labels` переезжает во внутренний `Core.Web.Event.Details`; публичного
`Core.Web.Labels` больше нет. Wire `title` / `details` не меняется. Спека — `../spec.md`, «Wire сведений»,
user story 4; ADR-0066.

- [x] Опция `labels:` — boolean, по умолчанию `false`; `labels: true` без `user_ref:` — `CompileError`.
- [x] `Core.Web.Event.Details` (`@moduledoc false`) — дамп сведений бывшего `Core.Web.Labels` с теми же
      `codec:` и `user_ref: [dump:]`, что у события; `Core.Web.Labels` удалён.
- [x] Тесты `Core.Web.Labels` переезжают на `Core.Web.Event` с `labels: true`; ожидаемый JSON `title` /
      `details` не меняется.
- [x] Фикстура-потребитель: `use Core.Web.Labels` → `use Core.Web.Event, labels: true`; `make consumer-check`
      зелёный.
- [x] Своды: `docs/rules/11-domain.md`, «Wire сведений», и `docs/rules/app/15-web-api.md` — `Core.Web.Labels`
      → `Core.Web.Event` с `labels: true`; `docs/rules/10-architecture.md` — строка `Core.Web.Labels` удалена.
- [x] `CHANGELOG.md`, «Новое» — пункт о `Core.Web.Labels` вливается в пункт о `Core.Web.Event`; правка
      `app/**` — тем же коммитом.
- [x] `make` зелёный.
