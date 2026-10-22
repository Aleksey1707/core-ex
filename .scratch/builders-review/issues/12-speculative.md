# 12: Speculative — View по kind, режимы разбора опций, рефлексия redump

**Status:** needs-triage

**Blocked by:** None

**Сила:** Speculative. Выигрыш мал или зависит от других кандидатов. Решить, брать ли пункты в работу.

## View: выбор по kind разнесён по трём файлам

**Файлы:** `lib/core/view.ex` (`type_ast` ~186–193), `lib/core/view/dumper.ex` (`dump_ast` ~85–125), `lib/core/view/opts.ex` (`spec!`, `needs_codec?`, `collect_forms`).

Новый kind View требует правки 4–5 функций в трёх файлах: модули поделены по фазе (разбор, тип, дамп), а не по понятию. По deletion test `Dumper` (146 строк) просто переедет в `view.ex`. Для сравнения, грамматика плагина держит все kind'ы в одном файле. Выигрыш — locality при добавлении kind'а, он скромный.

## Три режима разбора опций `use`

- При раскрытии макроса (`Macro.expand_literals`): `Aggregate`, `Cmd`, `Repo`, `Process`, `KeyReservation`, `StateStored`.
- В теле модуля (`bind_quoted`): `Es.Event`, `Event.Payload`, `Repo.Pg`, `Codec`.
- Смешанный режим с публичными `@doc false` валидаторами в атрибутах: `Event.Codec.type!/tags!/mods!/upcasts!/derive!`, `Projection.declaration!` — потому что `tags: @attr`.

`StateStored` проверяет ключи, а затем `use Core.Repo.Pg` проверяет их ещё раз. Типизированные валидаторы каждый билдер пишет сам: в зоне агрегатов около 82 `raise CompileError`. Большая часть уйдёт с кандидатами 07 и 11. Длинный `quote` в `Repo.Pg` уже записан в `DEBT.md`.

## Рефлексия redump и разбор ручных клауз

**Файлы:** `lib/core/codec/plugin/redump.ex` (~39–78), `lib/core/codec/facade.ex` (~139–189, `redump?`), `lib/core/codec/plugin/opts.ex` (~142–281), `lib/core/es/event/codec.ex` (~738).

- `__codec_redump_missing__/0` существует только ради success typing Dialyzer. Фасад генерирует три группы клауз и `redump?/1`, чтобы бросить ошибку вместо плагина.
- `Plugin.Opts` назван «опции», но половина модуля — разбор AST ручных клауз (`manual_targets`, `raise_never_match!`), который использует и Redump.
- `Es.Event.Codec` делает тот же разбор своим `Module.get_definition`.

Обход Dialyzer может быть вынужденным.

## Мелочь

`Es.Cmd.__es_cmd__/0` никто не читает, кроме `test/core/es/cmd_test.exs`.
