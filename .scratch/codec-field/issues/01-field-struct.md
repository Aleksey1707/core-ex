# 01: Поле спеки — struct в `Core.Codec.Field`

**What to build:** нормализованное поле спеки полей — struct `%Core.Codec.Field{}` с именованными ключами
(`name`, `spec`, `optional?`, `wire`, `default`, `subject`), а грамматика спеки (нормализатор с режимом
плагин / нагрузка / подписи и его проверки) живёт в новом модуле `Core.Codec.Field`. Все, кто читает поле,
читают его по ключам; `Es.ValueChanged` отдаёт свою спеку нормализатору. Поведение у потребителя не
меняется. Генерация ПДн-нагрузки пока остаётся в `Core.Codec.Plugin.Fields` — её переносит 02. Спека —
`../spec.md`, user stories 1–12, 16, 24–26, 28–29; «Implementation Decisions» — `Core.Codec.Field`,
читатели поля, `Es.ValueChanged`, `__es_payload_fields__/0`.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] `Core.Codec.Field`: struct поля с типом `t()` вместо прежнего типа поля в `Core.Codec.Plugin.Fields`;
      `spec`, `default`, `subject` — прежние значения.
- [ ] В `Core.Codec.Field` переехала грамматика: нормализация спеки плагина, нагрузки, вариантов семейства и
      подписей, `value_spec`, `struct_module!`, `subjects`, `typespec`, сверка ключей спеки с полями struct,
      проверки kind-ключа, `optional:`, `list:`, `wire:`, уникальности, `default:` и `subject:` по режиму.
- [ ] Тексты `CompileError` грамматики не изменились.
- [ ] Ни один модуль не разбирает поле позиционным кортежем: нагрузка события, подписи и их полнота,
      `ProjectionCase`, варианты семейства, redump плагина, `Es.Event`, тестовый хелпер ПДн,
      `Core.Codec.Plugin.Fields`.
- [ ] `Es.ValueChanged` строит keyword-спеку `old_value` / `new_value` и отдаёт её нормализатору; поле
      руками не собирается.
- [ ] `__es_payload_fields__/0` — `@doc false`; `@moduledoc` нагрузки описывает её как внутреннюю для
      `Core.Es.Event.Codec`.
- [ ] Новый тест-модуль нормализатора вызывает `Core.Codec.Field` напрямую, без сборки модулей: kind-ключ,
      `optional:` и `list:`, `wire:`, уникальность имён и wire-ключей, `default:` и `subject:` по режиму,
      форма возвращаемого struct.
- [ ] Существующие тесты плагина по полям, вариантов, redump, нагрузки (с ПДн и выведенной), `Es.ValueChanged`,
      подписей и проекций проходят; правлены только паттерны на форму поля из `__es_payload_fields__/0`.
- [ ] `docs/rules/11-domain.md` называет нормализатором спеки `Core.Codec.Field`.
- [ ] CHANGELOG не правится.
- [ ] `make` зелёный, включая `consumer-check`.
