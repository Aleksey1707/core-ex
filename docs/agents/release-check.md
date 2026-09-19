# Проверка на потребителе до релиза

Незапушенные изменения проверяются на приложении-потребителе в отдельной его ветке:
`{:core, path: "../core-ex"}` в `mix.exs`. В основную ветку потребителя такая строка не
коммитится — после релиза зависимость возвращается на `tag:`.

- `deps/core` при `path:` не обновляется: там остаётся checkout прежнего тега, а линтеры
  `deps/core/scripts/`, ярус свода `deps/core/docs/rules/` и скиллы потребителя читают именно его.
  Каталог заменяется симлинком на рабочую копию (`deps/core -> ../../core-ex`, прежний checkout
  переносится); возврат на тег — удалить симлинк и `mix deps.get`.
- PLT dialyzer устаревает молча: dialyxir сверяет хеш по `mix.lock`, а при `path:` lock не
  меняется — «PLT is up to date!» и ложные `call_to_missing` / `invalid_contract` / `no_return` на
  функциях `Core`. Перед `mix dialyzer` удаляется `_build/dev/dialyxir_*_deps-dev.plt*`.
- Сборка ловит не каждую прежнюю форму: после `mix compile --force --warnings-as-errors` код
  проходится по «было → стало» раздела «Не выпущено» `CHANGELOG.md` и по карте устаревших форм
  `docs/rules/app/00-index.md`.
