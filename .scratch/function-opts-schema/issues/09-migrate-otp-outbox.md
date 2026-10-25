# 09: Перевод OTP на схему — outbox

**What to build:** дерево outbox и его тестовый дублёр проверяют опции схемой: опечатка в опциях
`Outbox.Supervisor`, поллера или `Outbox.Test` падает с именем ключа.

Спека — «Объём перевода», волна 2.

**Blocked by:** 07

**Status:** ready-for-agent

- [ ] Схема над `init/1` у `Outbox.Poller`, `Outbox.Test.Reactor`; `Outbox.Supervisor` — схема в
      месте, где он сейчас разбирает опции (`options!`), и решение по `watch_list` записано в
      `## Comments`.
- [ ] `Outbox.Test.drain` / `settle` переведены на схему; вызовы `StartOpts` убраны.
- [ ] Опции в `@moduledoc` из схемы у процессов с `@doc false` на `init/1`.
- [ ] Тесты старта с неверными опциями и тесты `Outbox.Test` зелёные (тексты обновлены).
- [ ] CHANGELOG: функции, где неизвестный ключ раньше проходил, добавлены в список «Ломающих».
- [ ] `make` зелёный.
