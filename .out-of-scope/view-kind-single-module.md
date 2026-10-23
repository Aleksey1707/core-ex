# View: код kind'а в одном модуле

`Core.View` поделён по фазе: разбор спеки полей (`Core.View.Opts`), typespec (`Core.View`), дамп
(`Core.View.Dumper`). Каждый kind поля (`prim` / `enum` / `type` / `view` / `form` / `list` / `jsonb`)
разбирается в трёх местах. Перегруппировать код по kind'у или влить `Dumper` в `Core.View` библиотека
не будет.

## Почему это вне рамок

Новый kind требует правки 4–5 функций в трёх файлах, но kind'ы View добавляются редко: набор закрыт
семантикой read-модели, и новый kind — уже решение уровня ADR, на фоне которого правка трёх файлов
незаметна.

Слияние `Dumper` в `Core.View` — по deletion test это перенос, а не углубление: сложность не исчезает,
`view.ex` вырастает до ~360 строк и смешивает typespec с генерацией дампа. Разбиение «по kind'у»
(module на kind с `spec!` / `type_ast` / `dump_ast`) даёт семь мелких модулей с одинаковым interface
— shallow.

Сравнение с грамматикой Codec-плагина, где kind'ы держит один файл, не переносится: там kind
определяет и разбор, и dump/load, и redump одной структурой (`Core.Codec.Field`), у View три фазы
работают над разными представлениями (AST спеки, typespec, quote дампа).

## Prior requests

- `.scratch/builders-review/issues/12-speculative.md` — «View: выбор по kind разнесён по трём файлам»
  (ревью билдеров, 2026-10-22).
