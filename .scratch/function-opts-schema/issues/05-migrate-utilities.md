# 05: Перевод на схему — утилиты

**What to build:** утилиты библиотеки отклоняют опечатку в опциях `ArgumentError`:
`DurationParser.parse(s, :s, roundng: :up)` больше не округляет молча по умолчанию.

Спека — «Объём перевода», волна 1.

**Blocked by:** 02

**Status:** resolved

- [x] Классифицированы и переведены `DurationParser` (`parse`, `to_duration`, `to_timeout` и их
      bang-варианты), `Cgroup`, `Helper.Lock`, `Helper.Keys`, `Error.has?`,
      `Mq.Stream.Credentials.new`; bang-вариант, передающий опции в safe, — без схемы; функция без
      схемы — с обоснованием в `## Comments`.
- [x] Ручные `Keyword.validate!` и проверки типа убраны; ручная проза об опциях в `@doc` убрана.
- [x] Тесты модулей: по одной проверке «неизвестный ключ → `ArgumentError`»; остальные зелёные.
- [x] CHANGELOG: переведённые публичные функции добавлены в список пункта «Ломающие изменения
      контракта».
- [x] `make` зелёный.

## Comments

- Классификация:
  - `DurationParser.parse/3`, `to_duration/2`, `to_timeout/2` — схема `rounding:` (`{:in,
    Rounding.values()}`, умолчание `:no`) одним атрибутом `@rounding_schema`; `rounding!/1` и
    `checked_rounding/1` удалены. `parse!/3`, `to_duration!/2`, `to_timeout!/2` передают опции в
    safe-функцию — без схемы.
  - `Cgroup.memory_current/1`, `memory_anon/1`, `memory_max/1` — у каждой свой явный путь плюс общий
    `@location_schema` (`mount_point:`, `self_cgroup_path:` с умолчаниями из атрибутов модуля).
    `Cgroup.PromEx` раньше отдавал всем трём один и тот же список путей: теперь каждой — её путь и
    `mount_point:` (приватный `location/2`), иначе соседний ключ отклонялся бы.
  - `Helper.Lock.advisory_xact!/3`, `with_advisory!/4` — `lock_timeout:` (строка, умолчание `"5s"`)
    и `timeout:` (`:timeout`, без умолчания: Ecto берёт своё); `try_advisory_xact/3` — только
    `timeout:`: блокировку она не ждёт, и `lock_timeout:` у неё не действовал бы. Это не «опции
    насквозь»: в Ecto уходит `Keyword.take(opts, [:timeout])`, и прочие ключи там никто не увидел
    бы — проверять их больше некому.
  - `Helper.Keys.camelize/2`, `snakify/2` — `except:` (`{:list, {:or, [:atom, :string]}}`,
    умолчание `[]`).
  - `Mq.Stream.Credentials.new/1` — схема из пяти ключей с прежними умолчаниями; `from_env/2` зовёт
    `new/1` и схемы не несёт. Пароль проверяется custom-типом `Credentials.Password.validate/1`
    (вложенный модуль с `@moduledoc false`): встроенный `:string` напечатал бы значение в тексте
    `ArgumentError` («got: …»), а к сообщению custom-типа NimbleOptions значение не добавляет.
    Вложенный модуль собран до функций внешнего, поэтому проверка умолчаний при сборке его видит.
  - `Error.has?/2` — **без схемы**. Второй аргумент — фильтр поиска (данные вызова: что искать), а
    не опции (`CONTEXT.md`, «Опции функции»). Непустота фильтра — домен функции в голове
    (`[_ | _] = opts`, тест «пустой критерий → `FunctionClauseError`»); схема требует голую
    переменную, и пустой список вернулся бы ручной проверкой в теле. `Keyword.*` / `opts[:…]` в теле
    нет — будущая `CredoChecks.OptsSchema` (тикет 11) её не заденет.
- Ключ схемы без умолчания (`current_path:` и т.п. у `Cgroup`, `timeout:` у `Lock`) тело читает
  `Keyword.get/2` без запасного значения: `Keyword.fetch!/2` из правила свода — для ключей с
  умолчанием, отсутствие такого ключа — штатный случай.
- Проза об опциях в `@moduledoc` (`DurationParser` — значения и умолчание `rounding:`, `Helper.Keys`
  — тип `except:`) сокращена до ссылки и семантики: тип и умолчание даёт раздел «Опции».
- `docs/rules/DEBT.md`, «Опции функций `lib/` мимо схемы»: перечисление функций заменено ссылкой на
  список CHANGELOG — следующим срезам править запись не нужно.
- Тест-окружение: `config :core, Core.Mq.Stream` несёт рядом с credentials `lazy:`. `test_helper.exs`
  вынимает его `Keyword.pop!/2` до `Credentials.new/1`, `connection_ids_test.exs` (`:rabbit_stream`)
  — `Keyword.delete/2`. У потребителя с такой же секцией под `from_env/2` — то же; CHANGELOG
  называет правку.
- Тесты: по одной проверке «неизвестный ключ → `ArgumentError`» с префиксом `Mod.fun/n:` в
  `duration_parser_test`, `cgroup_test` (ключ соседней функции), `keys_test`, `lock_test`,
  `credentials_test`. Прежний тест «неизвестная политика округления → `FunctionClauseError`»
  переписан на `ArgumentError`; в `credentials_test` добавлен тест «пароль не строкой — без значения
  в тексте».
- Пересмотрено после тикета 10 (решение пользователя): `Credentials.from_env/2` берёт из секции
  только пять ключей `new/1` (`Keyword.take/2` по `@enforce_keys`) — секция конфига — данные
  приложения, и `lazy:` рядом её не ломает; `new/1` остаётся строгим. Правка потребителя под
  `from_env/2` больше не нужна (CHANGELOG поправлен). В тестах `lazy:` вынимается только перед
  прямым `new/1` (`test_helper.exs`, `connection_ids_test.exs`) — так и осталось.
