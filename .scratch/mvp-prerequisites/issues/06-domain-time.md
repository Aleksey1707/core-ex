# 06: Доменное время

**What to build:** «сейчас» значений даты и времени идёт через `Core.Clock`. Тест потребителя останавливает и
сдвигает время своего процесса и тех, кто его видит, и при этом остаётся `async: true`. Инфраструктура библиотеки
живёт по реальному времени.

Спека — «Доменное время»; ADR-0083; `CONTEXT.md` — «Доменное время».

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] Behaviour `Core.Clock` с `now/0` → UTC `DateTime` с микросекундами, системная реализация по умолчанию.
      Ключ `clock:` в `Core.Config` читается в рантайме.
- [ ] Генерируемые `now/0` и `now!/0` у `use Core.Prim.DateTime` и `use Core.Prim.Date` берут время у `Core.Clock` и
      приводят его к поясу и точности Prim.
- [ ] Инфраструктура берёт реальное время явно:
      - время записей outbox;
      - поллер, cleaner;
      - хранилище ключей субъектов;
      - читатель проекции;
      - метрики.
- [ ] Время события уничтожения ключа субъекта — доменное.
- [ ] `Core.Clock.Test` на `nimble_ownership` (новая обычная зависимость): `start/0`, `freeze/1`, `advance/1`
      (`Duration` или keyword `DateTime.shift/2`), `allow/2`, глобальный режим. Поиск: `self()` → `$callers` →
      разрешения, иначе реальное время. `advance/1` без `freeze` — ошибка программиста.
- [ ] Тесты:
      - `freeze` и `advance`;
      - `Task` через `$callers`;
      - `allow/2`;
      - глобальный режим;
      - изоляция параллельных тестов;
      - реальное время без `freeze`;
      - время outbox при остановленных часах реальное.
- [ ] `make consumer-check` без новых предупреждений у генерируемых `now/0` / `now!/0`.
- [ ] Своды `11-domain.md` и `19-testing.md`. App-ярус: `clock:` в `config/test.exs` и `Core.Clock.Test.start()` в
      `test_helper.exs`.
- [ ] CHANGELOG «Новое».
- [ ] `make` зелёный.
