# 01: `Mq.Lease` — один порт аренды

**What to build:** Kafka-читатель и DLQ-читатель создают токен аренды, считают её срок и сообщают о
потере одинаково: один внутренний порт аренды, хранение и SQL остаются у адаптеров. Outbox не
переводится на общий порт — у него свои часы, свой Prim токена и своя семантика лога. Спека —
`.scratch/mq-lease-reader/spec.md`.

**Blocked by:** None (can start immediately).

**Status:** resolved

- [ ] Один внутренний модуль аренды: новый токен, срок, нормализованный отказ «аренда потеряна»; `@doc false`.
- [ ] Kafka-хранилище и DLQ-хранилище используют его вместо собственных копий типа и создания токена.
- [ ] Потеря аренды даёт один и тот же код и форму detail у обоих читателей; запись результата под чужой арендой по-прежнему не проходит.
- [ ] Wire-формат, миграции и таблицы не меняются; outbox остаётся на своих часах и токене.
- [ ] Тесты store и читателей зелёные, включая живые брокеры: `make`, `make test-stream`, `make test-kafka`.
- [ ] CHANGELOG не меняется: модуль внутренний, поведение видимой поверхности прежнее.

## Comments

Resolved in `7ed2558`. `Core.Mq.Lease` holds the token, the local
deadline and the normalized `:lease_lost` error; Kafka and DLQ stores delegate creation and
build the same code/detail (`scope: :kafka | :dlq`). Public store `lease` types restored in
review fixes (`e93c502`). CHANGELOG records the consumer-visible code change — the
same-code criterion of the ticket wins over its "CHANGELOG unchanged" line. `make`,
`make test-stream`, `make test-kafka` green.
