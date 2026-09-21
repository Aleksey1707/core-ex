# 01: Поле `errors` и конструктор `Error.many/1,2`

**What to build:** `%Error{}` умеет нести множество независимых отказов. Контейнер собирается
`Error.many/1,2`, `kind` выводится из состава, инварианты состава проверяются на сборке
контейнера, а причиной контейнер быть не может.

**Blocked by:** —

**Status:** ready-for-agent

**Spec:** [Множество ошибок](../spec.md) — «Тип и конструктор»

- [x] `defstruct` получает `errors: []`; поле вне `@enforce_keys`, `@type t` дополнен
      `errors: [t()]`; `@moduledoc` называет отличие `errors` от `parent`.
- [x] `Error.many/1` (module из `__CALLER__`) и `Error.many/2` (явный module) — макросы рядом с
      `domain` / `app`; литеральный kwlist проверяется на compile-time тем же
      `validate_factory_opts!`: обязательны `code:`, `ns:`, `message:`, `errors:`, опциональны
      `detail:`, `parent:`. Динамический attrs — runtime-проверка, как у существующих.
- [x] `kind` не принимается опцией: хотя бы один элемент `kind: :app` → контейнер `:app`, иначе
      `:domain`.
- [x] `ArgumentError` с текстом правила: пустой `errors:`; элемент не `%Error{}`; элемент с
      непустым `errors` (множество плоское).
- [x] Контейнер не бывает причиной: `wrap(_, %Error{errors: [_ | _]})` и `parent:` с контейнером
      у `domain` / `app` / `many` — `ArgumentError` «множество ошибок не может быть причиной».
      Обратное направление (`many(parent: обычная)`) работает.
- [x] Порядок элементов — порядок входа; дубли `{ns, code}` не схлопываются; множество из одного
      элемента собирается наравне с прочими.
- [x] `test/core/error_test.exs`: конструктор и compile-check ключей, вывод `kind` (все `:domain`,
      один `:app`, все `:app`), каждый `ArgumentError`, порядок и дубли, `parent` у контейнера,
      независимость `errors` и `parent`.
- [x] Разметка `error.ex` — блоки `# ===== … =====` по `20-agreements.md`, раз публичных групп
      становится больше одной.
