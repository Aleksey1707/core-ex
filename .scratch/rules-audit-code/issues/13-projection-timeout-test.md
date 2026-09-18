# 13: Тест ответа 202 на таймаут проекции

**Status:** done

**What to build:** способ проверить в тесте ветку `:projection_timeout` / `:projection_rebuilding` при
тестовом дереве `await: :inline` (там таймаута нет, иной исход — `RuntimeError`).

**Why:** ветку 202 из `app/15-web-api.md`, «Ожидание проекции» приложение проверяло своим хелпером, который
правил отметку дерева и env таймаута самого приложения.

## Решение

`Core.Es.Projection.Test.with_rebuilding/2` — подставленная пересборка на время блока, а не ожидание таймаута:

- на время блока отметка дерева переводится на `await: :poll`, строка чекпоинта снимается — `await/3` отдаёт
  `:projection_rebuilding` мгновенно, таймаут вызывающего не читая;
- в `after` возвращаются и отметка, и строка со своей позицией: следующий `run_until_idle/2` досчитывает
  события, а не зовёт `clear/0`;
- опции дерева хелпер берёт из отметки (`Mark.find()`), потребитель их не передаёт;
- контракт `await/3` (ADR-0013) не менялся: третьего режима нет.

SQL удаления и восстановления строки — `@doc false` `Checkpoint.delete/1` и `Checkpoint.restore/2`: запросы к
`es_checkpoints` остаются в одном модуле.

Нормы: `19-testing.md`, «Ветка неготовой read-модели» (механика, `:poll` потребителю MUST NOT,
`:projection_timeout` интеграционно MUST NOT); `app/19-testing.md`, «Event sourcing» (один тест на
приложение); `app/15-web-api.md`, «Ожидание проекции» (отсылка).

Тест: `test/core/es/projection_test.exs`, `describe "Test.with_rebuilding/2"`.

## Следом, в других репозиториях

- **qc:** перевести 4 теста на 1, удалить `test/support/projection_await.ex`; `await_timeout_ms:` остаётся
  ops-ручкой. Поедет с бампом git-зависимости.
- **counters:** ветка 202 в `lib/counters_web/api/v1/counter/controller.ex` без теста.
