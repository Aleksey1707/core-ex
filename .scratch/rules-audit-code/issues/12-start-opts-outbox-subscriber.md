# 12: `StartOpts` в `Outbox.Poller`, `Outbox.Cleaner`, `MqSubscriberReliable`

**Status:** needs-triage

**What to build:** разбор опций процессов через `Core.Helper.StartOpts` с проверкой типов и значений.

**Why:** `17-otp-concurrency.md` требует проверку опций при разборе; эти процессы читают `Keyword.fetch!` /
`Keyword.get` без проверки. Отступление записано в `docs/rules/DEBT.md` — запись снимается этим тикетом.

- [ ] перевод и тесты на недопустимые значения; запись в `DEBT.md` удалить
