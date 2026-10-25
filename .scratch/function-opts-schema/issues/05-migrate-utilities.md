# 05: Перевод на схему — утилиты

**What to build:** утилиты библиотеки отклоняют опечатку в опциях `ArgumentError`:
`DurationParser.parse(s, :s, roundng: :up)` больше не округляет молча по умолчанию.

Спека — «Объём перевода», волна 1.

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] Классифицированы и переведены `DurationParser` (`parse`, `to_duration`, `to_timeout` и их
      bang-варианты), `Cgroup`, `Helper.Lock`, `Helper.Keys`, `Error.has?`,
      `Mq.Stream.Credentials.new`; bang-вариант, передающий опции в safe, — без схемы; функция без
      схемы — с обоснованием в `## Comments`.
- [ ] Ручные `Keyword.validate!` и проверки типа убраны; ручная проза об опциях в `@doc` убрана.
- [ ] Тесты модулей: по одной проверке «неизвестный ключ → `ArgumentError`»; остальные зелёные.
- [ ] CHANGELOG: переведённые публичные функции добавлены в список пункта «Ломающие изменения
      контракта».
- [ ] `make` зелёный.
