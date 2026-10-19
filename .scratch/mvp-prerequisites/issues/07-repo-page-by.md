# 07: `Repo.Pg.page_by`

**What to build:** ReadRepo отдаёт страницу выборки с фильтром и общее число по тому же фильтру. Форма фильтра та же,
что у `list_by`.

Спека — «Страница с фильтром».

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] `Repo.Pg.page_by(pg, filter, limit, offset, context, opts \\ [])` рядом с `list_by/4`:
      - фильтр — `Ecto.Query.dynamic_expr()`;
      - `limit` и `offset` — Prim `Core.Pagination`;
      - возврат — `Pagination.Result`;
      - опции — те же, что у `page`.
- [x] `@doc`, `@spec` через типы `Core.Result` / `Pagination.Result`.
- [x] Тесты над таблицей фикстуры `TestRepo`: фильтр, страница, `total` по фильтру, пустая страница за концом.
- [x] Свод `13-repos.md` (Read) и CHANGELOG «Новое».
- [x] `make` зелёный.
