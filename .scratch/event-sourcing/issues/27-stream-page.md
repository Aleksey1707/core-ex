# 27: Страница потока `Core.Es.Store.page_stream/5`

**What to build:** автор usecase экрана истории читает страницу потока одного агрегата любого вида —
`Core.Es.Store.page_stream(Agg.Event.Codec, id, limit, offset, context)` → `Pagination.Result` из `Es.Event` — и отдаёт
её прежним презентером. Это замена `page_by_aggregate`, которую удаляет тикет 28.

**Blocked by:** [26: Хранилище событий](26-event-store-append.md)

**Status:** ready-for-agent

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Хранилище событий», пункт `page_stream`

- [ ] Возврат `{:ok, Pagination.Result.t(Es.Event)}` по `Pagination.Limit` / `Pagination.Offset`: порядок — по
      возрастанию `aggregate_version`, `count` — весь поток; тип агрегата и семейство событий — из кодека.
- [ ] Условия `pg_snapshot_xmin` в запросе нет.
- [ ] Строки грузятся фасадом `InCodec.load(Agg.Event, wire)`, апкаст действует; первая ошибка `load`
      (`:unknown_event_type`, `:invalid_envelope`) — `{:error, _}` на всю страницу через `Result.traverse`, без
      `raise`.
- [ ] Пустой поток — страница с `count: 0`, `:not_found` нет; доступ не проверяется; `context` — последний из данных и
      не используется; `opts`, span и telemetry нет.
- [ ] Тесты: страница и `count`; `offset` за концом потока; пустой поток; поток того же `aggregate_id` другого типа
      агрегата на страницу не попадает; событие с неизвестным тегом даёт ошибку всей страницы.
- [ ] `13-repos.md`: H2 «Страница потока» — `page_stream/5`; MUST проверить права и существование агрегата через
      `ReadRepo.get(id, :current, context)` до чтения (плохо / хорошо); `Es.Event` вместо View со ссылкой на ADR-0010;
      ошибка `load` на всю страницу; поток нескольких агрегатов — проекция; слово «страница потока», не «история».
- [ ] `make` зелёный.
