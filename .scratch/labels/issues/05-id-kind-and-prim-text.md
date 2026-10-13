# 05: Вид id и Prim текстом

**Status:** resolved

**Blocked by:** 03.

**What to build:** автор приложения объявляет у Prim-идентификатора, как id выходит в сведения
(`use Core.Labels.ID, kind:`): ссылкой на запись (`:ref`, вид записи атомом и резолвер), ссылкой на учётную запись
(`:user`, резолвер) или только id (`:id`, текстом). У Prim, который человеку показывают текстом, — функция текста
(`use Core.Labels.Text, with:`). Map'а с id в ключах подписывает ключ и значение (`[label:, key:, value:]`) и
выходит списком групп «ключ — значение». Спека — `../spec.md`, «Модули домена», user stories 9, 21–27, 37; ADR-0063.

- [x] `use Core.Labels.ID` после `use Core.Prim.*`: `kind:` из `~w(ref user id)a`; `entity:` — атом, обязателен
      у `:ref`, запрещён у остальных; `resolver:` обязателен у `:ref` и `:user`, запрещён у `:id`; без
      `use Core.Prim` — `CompileError`. Публичная интроспекция «объявление или `nil`» по модулю.
- [x] `use Core.Labels.Text` после `use Core.Prim.*`: `with:` — захват функции арности 1, иначе `CompileError`;
      без `use Core.Prim` — `CompileError`. Публичная интроспекция «функция или `nil`».
- [x] `Details.build/1`: `:user` — `%{kind: :user, value: id}`; `:ref` — `%{kind: :ref, entity: атом, value: id}`;
      `:id` — `text` с id; Prim с `Core.Labels.Text` — `text` с результатом функции, в том числе код внутри
      Prim-композита; map'а с `[label:, key:, value:]` — `list` из групп «ключ — значение».
- [x] Id без `Core.Labels.ID` в сведениях — документированное исключение с именем модуля.
- [x] Отказы сборки `Fields`: подписи map'ы у поля, которое не map'а; неизвестный ключ в `[label:, key:, value:]`.
- [x] Тесты: каждый вид id, Prim текстом, map'а с id в ключах, исключение у id без вида, отказы сборки.
- [x] Фикстура-потребитель: Prim-идентификатор каждого вида и Prim с текстом; `make consumer-check` зелёный.
- [x] Свод: механизм — `docs/rules/11-domain.md`, «Подписи»; `docs/rules/app/11-domain.md` — у каждого
      Prim-идентификатора, достижимого из сведений, объявлен вид.
- [x] `CHANGELOG.md` — дополняется пункт подсистемы подписей.
- [x] `make` зелёный.
