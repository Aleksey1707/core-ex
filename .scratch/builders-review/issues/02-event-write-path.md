# 02: Запись событий агрегата — один module

**Status:** needs-triage

**Blocked by:** None (can start immediately)

**Сила:** Strong.

**Файлы:**
- `lib/core/es/aggregate/repo/pg.ex` — `write/4` (~668–679), `page_stream` (~252–270), `behaviour!` (~319);
- `lib/core/repo/pg/state_stored.ex` — `flush_events` / `do_flush_events` внутри `quote` (~205–233), `page_stream` (~276–298), `behaviour!` (~300);
- `test/core/es/operation_test.exs` — describe «event-sourced агрегат» (~28) и «state-stored агрегат с событиями» (~111).

**Проблема.** Конвейер `Es.Operation.stamp` → `outbox.from_events` → `Es.Store.append` → `Personal.Wire.seal_records` → `Config.outbox_repo().append` написан дважды. В event-sourced пути это обычная функция, где между шагами вставлен `KeyReservation.append`. В state-stored пути — код внутри `quote` у потребителя: вызвать или протестировать его как функцию нельзя, поэтому одно и то же свойство проверяют два теста. Тело `page_stream` совпадает дословно, `behaviour!` тоже написан дважды.

**Что изменилось бы.** Порядок «события → резервы → outbox» принадлежит одному module библиотеки, и оба репозитория зовут его. В `quote` остаётся только сужение результата по ADR-0014.

**Выигрыш.** Locality: штамп операции и шифрование ПДн правятся в одном месте. Свойство пути проверяет один тест. `quote` у `StateStored` становится меньше.

**ADR:** конфликта нет. Сужение результата по ADR-0014 сохраняется.
