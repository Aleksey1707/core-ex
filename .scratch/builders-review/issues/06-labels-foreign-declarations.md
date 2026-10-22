# 06: Labels — явный interface чтения чужих объявлений

**Status:** needs-triage

**Blocked by:** 03 — Чтение подписей (желательно, не строго)

**Сила:** Worth exploring.

**Файлы:**
- `lib/core/labels/{text,values,fields,id,event}.ex`;
- `lib/core/labels/check.ex` — `prim!`;
- `lib/core/web/event.ex` (~180–185);
- `test/core/labels/fields_test.exs` — около 80 проверок `CompileError`.

**Проблема.**
- Labels читают приватные атрибуты чужих макросов: `:enum_values` (`values.ex` ~94), `:es_payload_fields` (`fields.ex` ~197) и `:es_value_changed` (`fields.ex` ~236). Если переименовать `@enum_values`, ошибка молча превращается в «не Enum».
- `Check.prim!` проверяет `__domain_kind__/0`, `__label_id__/0` и `__label_text__/0` через `Module.defines?`.
- Шесть модулей повторяют один шаблон: `quote bind_quoted`, `Helper.Opts.validate!(opts, X.required_keys(), X.optional_keys(), …)`, публичные pass-through `required_keys/0` и `optional_keys/0` (12 функций), копии `where/1` и `reject!` / `fail!`.
- View и CompletenessCase проверяют опции при раскрытии макроса (`Macro.expand_literals`) — это вторая стратегия той же задачи.
- `declare!` нельзя вызвать вне собираемого модуля, поэтому тесты компилируют модули целиком.

**Что изменилось бы.** Enum, Payload и ValueChanged получают явный interface для чтения при компиляции. Labels берут оттуда готовые данные и становятся чистыми функциями от них.

**Выигрыш.** Тесты на уровне функций. Seam к Enum и Payload становится явным. Шаблонный код уходит из шести модулей.

**ADR:** конфликта нет.

**Связь с `.scratch/codec-field/`.** Если `:es_payload_fields` станет списком `%Core.Codec.Field{}`, часть утечки уйдёт сама. Это нужно перепроверить перед проработкой.
