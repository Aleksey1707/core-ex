# 08: Перевод OTP на схему — брокеры

**What to build:** читатели и писатели брокеров проверяют опции старта схемой над `init/1`;
опечатка в дереве супервизии — `ArgumentError` в `init/1` с именем ключа, а не молчаливый backoff,
неотличимый от недоступного брокера.

Спека — «Объём перевода», волна 2.

**Blocked by:** 07

**Status:** ready-for-agent

- [ ] Схема над `init/1` у `Mq.Stream.Reader`, `Mq.Stream.Writer`, `Mq.Kafka.Reader`,
      `Mq.Dlq.Reader`, `Mq.Dlq.Writer`; вызовы `StartOpts` убраны; `child_spec` / `start_link` без
      схемы; опции в `@moduledoc` из схемы.
- [ ] `Mq.Client.ensure_available!` переведён на схему.
- [ ] После правки `lib/core/mq/**` — `make compile-no-optional` зелёный.
- [ ] Тесты старта с неверными опциями зелёные (тексты обновлены); тесты под тегами
      `:rabbit_stream` / `:kafka` не ломаются.
- [ ] CHANGELOG: функции, где неизвестный ключ раньше проходил, добавлены в список «Ломающих».
- [ ] `make` зелёный.
