# 07: `Repo.Pg.page_by`

**What to build:** ReadRepo отдаёт страницу выборки с фильтром и общее число по тому же фильтру. Форма фильтра та же,
что у `list_by`.

Спека — «Страница с фильтром».

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] `Repo.Pg.page_by(pg, filter, limit, offset, context, opts \\ [])` рядом с `list_by/4`:
      - фильтр — `Ecto.Query.dynamic_expr()`;
      - `limit` и `offset` — Prim `Core.Pagination`;
      - возврат — `Pagination.Result`;
      - опции — те же, что у `page`.
- [ ] `@doc`, `@spec` через типы `Core.Result` / `Pagination.Result`.
- [ ] Тесты над таблицей фикстуры `TestRepo`: фильтр, страница, `total` по фильтру, пустая страница за концом.
- [ ] Свод `13-repos.md` (Read) и CHANGELOG «Новое».
- [ ] `make` зелёный.
