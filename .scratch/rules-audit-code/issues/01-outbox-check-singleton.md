# 01: Проверка единственности поллера в `Core.Outbox`

**Status:** needs-triage

**What to build:** чистая `Core.Outbox.check_singleton!/1` (опции вида `enabled?:`, `cluster_query:`,
`allow_cluster?:`) рядом с `validate_partition!/1`; `ArgumentError` с инструкцией при кластерном запуске
с включённым outbox без явного разрешения. Норма — `docs/rules/app/14-events-outbox.md`, «Единственность поллера».

**Why:** функцию упоминали свод и moduledoc `Core.Outbox`, но в библиотеке её нет; каждое приложение пишет
копию сама (копии у пяти потребителей), тестов у копий нет. Из свода имя убрано до появления функции.

- [ ] функция и тест в библиотеке; строка ратчета в `app/19-testing.md` — «`start/2` зовёт `check_singleton!/1`»
- [ ] ссылки в `14-events-outbox.md` / `app/14` / moduledoc `Core.Outbox`; CHANGELOG «Новое»
