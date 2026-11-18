# 01: Тип `key_reservations` в конфигурации репозитория — dialyzer потребителя

**What to build:** поле `key_reservations` у `Core.Es.Aggregate.Repo.Pg.Config.t/0` объявлено тем же типом,
что кладёт builder репозитория, — `[Core.Es.KeyReservation.declaration()]`. Регресс-тест сверяет тип поля
конфигурации с полем `Core.Es.Store.Write.Plan.t/0` и результатом `Core.Es.KeyReservation.declarations!/4`.
Репозиторий потребителя с `key_reservations:` больше не теряет тип под Dialyzer.

**Blocked by:** None (can start immediately)

**Status:** resolved

**Spec:** handoff вне репозитория (2026-11-18) — «дефект типизации `key_reservations` в 0.19.0-rc.1»

- [x] `lib/core/es/aggregate/repo/pg/config.ex`: тип поля `key_reservations` — `[module()]` → `[Core.Es.KeyReservation.declaration()]`.
- [x] `test/core/es/key_reservation_test.exs`: тип поля конфигурации равен типу поля `Store.Write.Plan` и
      типу результата `KeyReservation.declarations!/4`; тест красный до правки (`[module()]` против
      `[Core.Es.KeyReservation.declaration()]`), зелёный после.
- [x] `CHANGELOG.md`, «Не выпущено»: тип поля, механизм (struct конфигурации невозможен для Dialyzer),
      правка потребителя не требуется.
- [x] `make` зелёный.

## Comments

- 2026-11-18 — реализация:
  - вариант «dialyzer по test-сборке ядра» проверен и отклонён: прогон `MIX_ENV=test mix dialyzer` даёт
    десятки `unknown_type` в тестовых фикстурах (намеренно неполные типы), отдельная PLT test-окружения
    в `make` не оправдана;
  - вариант «dialyzer по фикстуре-потребителю» требует второй PLT либо анализа её ebin против PLT ядра:
    второй прогон красный не только на дефекте (сценарии-ловушки и `unknown_type`), а зелёного нуля после
    правки у такой связки нет — храповик получился бы с исключениями;
  - выбран храповик на объявления: тест ловит расхождение типа поля с планом и builder'ом без PLT и без
    исключений; приёмочный сигнал для реального потребителя — его собственный `dialyzer` после выпуска.
- 2026-11-18 — сквозная проверка правки: анализ ebin фикстуры-потребителя вместе с ebin ядра против PLT
  ядра даёт 0 предупреждений о недостижимости (до правки — 7: `pg.ex` «pattern can never match»,
  `no local return` у пяти usecase-функций). `mix dialyzer` ядра и `make` зелёные.
