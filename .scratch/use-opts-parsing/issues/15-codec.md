# 15: Codec — опции с вложенным модулем в теле

**What to build:** автор кодека получает ошибки ключей и формы опций `use Core.Codec`, `Core.Codec.Facade`,
`Core.Codec.Plugin` при раскрытии, а плагин с `types:` / `fields:` / `variants:` по модулю, вложенному ниже `use`,
собирается, и несобранный модуль даёт громкий `CompileError` «модуль недоступен», а не тихий пропуск. `plugins:
<App>.Codec.plugins()` и `types: Map.keys(…)` остаются законными; `union:` — литерал. Спека — `../spec.md`, «Codec»;
ADR-0085.

**Blocked by:** 10; `.scratch/aggregate-wiring/issues/16-family-codec-outbox.md` (меняет вложенный `use` в
`Es.Event.Codec`).

**Status:** resolved

- [x] `Codec`, `Codec.Facade`, `Codec.Plugin` (`Codec.Plugin.Opts`, `Codec.Plugin.Variants`, `Codec.Field`):
  `bind_quoted` → пролог при раскрытии. Выражения: `Codec.Facade` `plugins:`, `Codec.Plugin` `types:`.
- [x] Форма `types:` / `fields:` / `variants:` проверяется при раскрытии (`literal!`); проверки по модулям
  (`fields!` / `variants!`, struct, Prim) — в теле через `<key>!` на `unquote(Macro.escape(lit))`, отказ на несобранном
  модуле громкий (`Code.ensure_compiled!`).
- [x] Генерация клауз по `fields:` / `variants:` — в месте `use`, вторым `quote unquote: false`.
- [x] `Es.Event.Codec` передаёт `union:` модулем через `unquote`.
- [x] Тексты `types:` / `union:` / `loadable:` — с меткой `Codec.Plugin:`, тексты `Codec.Facade` — с меткой
  `Codec.Facade:`. `View.Dumper.codec_ast/3` не изменён.
- [x] `@moduledoc` называет опции-выражения и опции, чей модуль MAY быть вложен в вызывающего (`types:` / `fields:` /
  `variants:`).
- [x] Тесты: опечатка в ключе — при раскрытии, с меткой; нелитерал в опции-литерале — «ожидается литерал»; неверное
  выражение — в теле, с меткой; вложенный модуль ниже `use` — «модуль недоступен».
- [x] CHANGELOG: накопительный пункт (текст — спека). Нет — завести вместе со строкой «Версия библиотеки» в
  `docs/rules/app/00-index.md`; есть — дописать строки `use Core.Codec.Facade`, `use Core.Codec.Plugin`.
- [x] Файлы тикета сняты с храповика `excluded`; список опустел — `files: %{excluded: …}` удалён.
- [x] Приёмка: `make` целиком; `make consumer-check` без новых предупреждений; `mix xref graph --label compile`
  фикстуры не изменился, у библиотеки compile-рёбра только уходят.
- [x] После влития ветка `prototype/use-opts-mode` удаляется.

**Заметка:** тексты `Codec.Field` и `Codec.Plugin.Variants` переведены на путь через `: ` вместе с остальными
(`Codec.Plugin: fields: <Тип>: <поле>: …`, `Codec.Plugin: variants: <Тип>: …`, хвост «задано» → «получено»), без
модуля плагина; у нагрузки события и подписей через `: ` идёт часть пути, которую строит `Codec.Field` (свои
проверки `Es.Event.Payload` — срез 17). Ветка `prototype/use-opts-mode` не удалена: её читают параллельные срезы.
Удалена 2026-10-25, после влития всех срезов.
