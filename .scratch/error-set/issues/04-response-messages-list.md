# 04: Конверт ответа принимает список сообщений

**What to build:** `Response.error/2,3` умеет положить в `messages` несколько строк, чтобы состав
множества доезжал до клиента без сборки конверта руками.

**Blocked by:** —

**Status:** ready-for-agent

**Spec:** [Множество ошибок](../spec.md) — «Граница HTTP»

- [ ] `Core.Web.Response.__error__/3,4` получают clause на `[String.t()]`: `messages` — этот
      список как есть; строка по-прежнему заворачивается в один элемент.
- [ ] Билдер `use Core.Web.Response` отдаёт то же: `@spec` `error/2,3` расширяется до
      `String.t() | [String.t()]`.
- [ ] Пустой список — `FunctionClauseError` (ответ без сообщений собирать нечем).
- [ ] `ErrorMapper` не трогается.
- [ ] `test/core/web/response_test.exs`: список, строка, пустой список, конверт с данными.
