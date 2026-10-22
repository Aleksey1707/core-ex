# 09: Фасад Codec перестаёт знать про события

**Status:** needs-triage

**Blocked by:** None (can start immediately)

**Сила:** Worth exploring.

**Файлы:** `lib/core/codec/facade.ex`, `lib/core/es/event/codec.ex` (~163–280), `lib/core/codec/plugin/variants.ex`. `__codec_union__` читают 10 файлов в `lib/`.

**Проблема.**
- Обобщённый `Codec.Facade` в четырёх местах отдельно обрабатывает события:
  - `type_pattern` по `function_exported?(plugin, :__es_type__, 0)` уходит в `Core.Es.Check.event_pattern`;
  - `validate_es_types!`;
  - `validate_es_payloads!` — через `__es_mods__` и `Es.Event.Codec.plugin_payloads`;
  - `plugins!` сам добавляет `Core.Es.Personal.Event.Codec`.
- `Es.Event.Codec` — ручной плагин (`types:` + `union:`), который заново пишет `type/1`, `types/0`, `mod_by_tag/1` и `load_by_tag`. Те же `type/1`, `types/0` и загрузку по семейству `Plugin.Variants` уже генерирует (`plugin.ex` ~202–230).
- `__codec_union__` как «семейство событий» читают модули вне Codec: `es/store.ex`, `es/projection.ex`, `outbox/release.ex`, `es/key_reservation.ex` и другие.

**Что изменилось бы.** Плагин сам отдаёт фасаду паттерн сужения и свои проверки сборки, и фасад перестаёт знать о `Core.Es.*`. Разбор «тег → модуль» становится общим для событий и вариантов.

**Выигрыш.** Seam фасада снова обобщённый. Новый вид плагина не требует правки фасада.

**ADR.** ADR-0060 задаёт проверку нагрузки в фасаде — здесь нужен пересмотр места этой проверки, но не её смысла. ADR-0057 отверг `tags:` у вариантов, но не общий движок разбора тега.
