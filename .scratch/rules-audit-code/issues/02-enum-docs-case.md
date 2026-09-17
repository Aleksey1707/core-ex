# 02: Проверка описаний значений `Core.Enum`

**Status:** needs-triage

**What to build:** проверка «`@moduledoc` enum несёт строку таблицы на каждое значение» в библиотеке —
функция над `Code.fetch_docs/1` или `use Core.EnumDocsCase, otp_app:` по образцу `Core.Es.EventCompatCase`;
отбор модулей — `Core.Enum.enum?/1`, а не эвристика по функциям. Тест на enum самой библиотеки
(`Core.Outbox.Status`, `Core.DurationParser.*`, `Core.Web.Response.Code`).

**Why:** норма `11-domain.md`, «Описание значений в `@moduledoc`» проверяется только ратчетом приложения;
ратчет скопирован байт в байт в нескольких потребителях, у библиотеки проверки нет.

- [ ] проверка и тест; «Проверяется» в `11-domain.md` и `app/19-testing.md` — на неё; CHANGELOG «Новое»
