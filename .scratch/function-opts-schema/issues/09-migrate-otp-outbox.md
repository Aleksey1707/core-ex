# 09: Перевод OTP на схему — outbox

**What to build:** дерево outbox и его тестовый дублёр проверяют опции схемой: опечатка в опциях
`Outbox.Supervisor`, поллера или `Outbox.Test` падает с именем ключа.

Спека — «Объём перевода», волна 2.

**Blocked by:** 07

**Status:** resolved

- [x] Схема над `init/1` у `Outbox.Poller`, `Outbox.Test.Reactor`; `Outbox.Supervisor` — схема в
      месте, где он сейчас разбирает опции (`options!`), и решение по `watch_list` записано в
      `## Comments`.
- [x] `Outbox.Test.drain` / `settle` переведены на схему; вызовы `StartOpts` убраны.
- [x] Опции в `@moduledoc` из схемы у процессов с `@doc false` на `init/1`.
- [x] Тесты старта с неверными опциями и тесты `Outbox.Test` зелёные (тексты обновлены).
- [x] CHANGELOG: функции, где неизвестный ключ раньше проходил, добавлены в список «Ломающих».
- [x] `make` зелёный.

## Comments

- `Outbox.Supervisor`: `options!/1` приватная, а схемы над `defp` не бывает, поэтому схема
  `@tree_opts_schema` стоит над обоими публичными входами разбора — `start_link/1` и
  `watch_list/1`. Решение по `watch_list`: та же схема над самой функцией — отказ называет её
  (`…watch_list/1: …`), а опции проверяются «как в `start_link/1`», как обещал контракт. Раздел
  «Опции» получают оба `@doc`; в `@moduledoc` вместо списка «Opts» — ссылка на раздел и смысловые
  оговорки (обязательность при `enabled: true`, Prim, репозиторий очереди).
- Условная обязательность (`enabled: true`) схемой не выражается: обязателен только `enabled:`,
  прочие ключи — без `required:`; включённое дерево проверяет `cluster_query:` на наличие, а
  `@required_when_enabled` (числа) — на не-`nil`, и называет пропуски одним списком
  (`Outbox.Supervisor: enabled: true — нет обязательных опций […]`). `pollers:` — `default: []`:
  пропуск у включённого дерева ловит прежний отказ «`enabled: true` при `pollers: []`».
- Форму значений схема проверяет при любом `enabled:` — у выключенного дерева это новое (раньше
  оно читало только `pollers:`). Чтобы не ронять выключенную очередь с незаданным env, числовые
  опции — `{:or, [:pos_integer, nil]}`: `nil` = не задано. Изменение — в «Ломающих» CHANGELOG.
- Элемент `pollers:` — `{:list, {:keyword_list, @poller_opts_schema}}`: ключи и формы элемента
  проверяет схема (`invalid list element at position N in :pollers option: …`). `keys:` у списка
  NimbleOptions применяет к самому списку, поэтому вложенная схема — в типе, а описание её ключей
  вставлено в `doc:` ключа `pollers:` вызовом `Core.Options.docs/1` (из той же схемы, не проза).
  `writer:` / `via:` / `connection:` — `:any` с `type_doc:`: форму проверяют `StartOpts.process!/3`
  и `via!/1` (значения внутри дерева); «ровно один из `writer:` и `via:`», повторы имён и меток —
  вручную, как раньше.
- Новые custom-валидаторы в `StartOpts` (блок «custom-валидаторы схемы»): `atom/1` — атом, кроме
  `nil` (`name:` поллера и элемента `pollers:`; встроенный `:atom` пропускает `nil`); `binary/1` —
  непустая строка (`label:`; встроенный `:string` пропускает `""`).
- `Outbox.Poller.child_spec/1` больше не проверяет `name:` / `shutdown:` (как `Cleaner` в 07):
  `:id` — `Keyword.get(opts, :name) || __MODULE__`, `shutdown:` — из опций с умолчанием; оба ключа
  проверяет схема `init/1`. `delivery:` — `:any`: поллер стартует только из дерева, которое всегда
  отдаёт `%Core.Outbox.Delivery.Mq{}`, отказ на `nil` не нужен.
- `Outbox.Test.Reactor`: `subscribers:` — `{:list, :keyword_list}`, состав подписчика проверяет
  `Outbox.Test.check_subscribers!/1`; `owner:` — встроенный `:pid` вместо `owner!/1`.
- `Outbox.Test.drain/2`, `settle/2` — схема над функцией, проза об опциях из `@doc` перенесена в
  `doc:` ключей. Разбор подписчика (`parse_subscriber!/1`) остаётся на `StartOpts`: подписчик —
  элемент списка в форме `MqSubscriberReliable`, его ключи разбирает и `Step.new!/2` (тикет 10);
  свести его на схему — вместе с подписчиком дерева (10/11).
- CHANGELOG: все переведённые функции неизвестный ключ отклоняли и раньше; в общий список
  «Ломающих» добавлены `Outbox.Supervisor` (форма значений у выключенного дерева) и `Outbox.Test`
  (только текст отказа). `Outbox.Poller` не упомянут: он стартует только из дерева.
- Для тикета 11: после 09 в `lib/` вне переведённого остаются `StartOpts.raise_invalid!/4`
  (`Outbox.Supervisor`: `prim!`, `transport!`, `via!`) и разбор подписчика
  `Outbox.Test.parse_subscriber!/1` (`keys!`, `atom!`, `pos_integer!`, `raise_invalid!`);
  `topics_filter!/4` больше никем не зовётся. `connection:` / `via:` проверяются вручную
  (`process!/3`, `via!/1`): это процессы дерева, как `writer:`.
