# 03: Одна сверка версии

**What to build:** проверка ожидаемой версии и адреса версии строится одной функцией с одним builder'ом
detail; различие исходов — только `source: :expected` против `source: :address`. Пять почти одинаковых
сверок исчезают, коды `:version_mismatch`, форма detail и каталог ошибок write-репозитория не меняются.
Спека — `.scratch/es-read-engine/spec.md`.

**Blocked by:** A1 (`01-load-engine-extract`).

**Status:** resolved

- [x] Одна приватная сверка покрывает `get`, `get_many`, `get_at` и `get_many_at`; второго builder'а detail нет.
- [x] detail одинаков по форме во всех входах: `aggregate_id`, `expected`, `actual` (голова или `nil`), `source`.
- [x] Пакетное чтение по-прежнему отдаёт одну ошибку со списком detail в порядке пар.
- [x] `:current` у чтения на версии остаётся `FunctionClauseError`; повтор `Es.Transact` на `:address` не возникает.
- [x] Публичных функций и опций не добавлено; контрактные тесты зелёные; `make` зелёный.
