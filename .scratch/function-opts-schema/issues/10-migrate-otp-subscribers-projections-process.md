# 10: Перевод OTP на схему — подписчики, проекции, процесс агрегата

**What to build:** подписчики брокера, дерево проекций, процесс агрегата и health-plug проверяют
опции схемой; вызов `Agg.Process.execute` без опций не платит за проверку.

Спека — «Объём перевода», волна 2.

**Blocked by:** 07

**Status:** ready-for-agent

- [ ] `MqSubscriberReliable`, его `Step` и `Supervisor` (включая `watch_list`, `stream_readers`,
      `kafka_readers`): схема там, где опции разбираются; вызовы `StartOpts` убраны.
- [ ] `Es.Projection.Supervisor` (`start_link`, `watch_list`) переведён.
- [ ] `Es.Aggregate.Process`: `init` / `watch_list` и `execute` (`timeout:`) — схема; ручные
      `Keyword.validate!` и клауза `raise ArgumentError` на тип убраны.
- [ ] `Web.HealthPlug.init` переведён; решение (схема над обратным вызовом `Plug`) записано в
      `## Comments`.
- [ ] Опции в `@moduledoc` из схемы у модулей с `@doc false` на месте разбора.
- [ ] Тесты старта с неверными опциями и тесты процесса агрегата зелёные (тексты про `:timeout`
      обновлены).
- [ ] CHANGELOG: функции, где неизвестный ключ раньше проходил, добавлены в список «Ломающих».
- [ ] `make` зелёный.
