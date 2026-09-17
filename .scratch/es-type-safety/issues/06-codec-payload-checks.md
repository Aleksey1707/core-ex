# 06: Проверки кодека событий — `dump_payload`, `load_payload`, модуль нагрузки

**What to build:** автор кодека событий получает предупреждение при сборке, указывающее на строку
`use Core.Es.Event.Codec`, если у `dump_payload/2` или `load_payload/3` нет clause для события с нагрузкой или если
`load_payload/3` отдаёт нагрузку другого события — литералом или через `Payload.new`.

**Blocked by:** 01, 04

**Status:** ready-for-agent

**Spec:** [Типобезопасность потребителя `Core.Es`](../spec.md) — «Функции-проверки полноты»

- [ ] `__before_compile__` кодека генерирует по событиям `tags:` с нагрузкой, по механике тикета 04:
  - проверку `dump_payload/2` на событии, суженном по `payload:` — имя `"dump_payload/2 принимает <Event>"`;
  - проверку `load_payload/3` с литеральным модулем события и сопоставлением результата с
    `{:ok, %<Payload>{}}` — имя `"load_payload/3 отдаёт нагрузку <Payload>"`; clause `{:error, _}` размечена
    `generated: true` в meta, остальная проверка — нет.
- [ ] Кодек без событий с нагрузкой проверок нагрузки не получает.
- [ ] Фикстура: маркеры H1 (`dump_payload`), H1 (`load_payload`), H2 литералом, H2 через `Payload.new`. Корректные:
      кодек с `upcasts:`, `load_payload`, который никогда не возвращает ошибку, модуль нагрузки, общий у двух событий,
      — ноль предупреждений.
- [ ] moduledoc `Core.Es.Event.Codec` (проверки и их имена); `11-domain.md` / `14-events-outbox.md` — где описаны
      колбэки нагрузки.
- [ ] `CHANGELOG.md`, «Не выпущено»: пункт кодека событий дополнен.
- [ ] `make` зелёный.

Prior art: `.scratch/es-type-safety/prototype/lib.diff` (`event/codec.ex`), раздел P2 в `RESULTS.md` (H1, H2, находка
про `Payload.new` на проходе проверки).
