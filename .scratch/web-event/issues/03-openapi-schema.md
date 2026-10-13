# 03: OpenAPI-схема события страницы событий

**Status:** resolved

**Blocked by:** 01, 02.

**What to build:** у приложения с `open_api_spex` модуль с `use Core.Web.Event` становится схемой события
страницы событий, а при `labels: true` порождает вложенную схему сведений. Страница описывается
`Response.Schema.page(MyAppWeb.Schemas.Event)`. Без `open_api_spex` модуль — только дамп. Спека — `../spec.md`,
«Схема», user stories 14–19; ADR-0064, ADR-0066.

- [x] Наличие `open_api_spex` — при раскрытии `use`; модули библиотеки на `OpenApiSpex` безусловно не ссылаются;
      `make compile-no-optional` зелёный.
- [x] При `open_api_spex` `user_ref: [schema:]` обязательна, иначе `CompileError`; без него — не требуется.
- [x] Схема события: название — последний сегмент имени модуля; объект открытый; required — все поля; `type` —
      строка без перечисления; `version` — `integer`, `minimum: 1`; `payload` — без типа, nullable; `at` —
      `date-time`; `by` — `string` или `schema:` из `user_ref:`; `title` / `details` — только при `labels: true`.
- [x] Схема сведений — вложенный модуль `Detail` (`<Имя>Detail`, виды — `<Имя>DetailText`, …), форма — как у
      бывшего `Core.Web.Labels`.
- [x] Тест: дамп `to_wire/2` каждой конфигурации и страница `Response.page_data/2` сверяются со схемой того же
      `use` и `Response.Schema.page/1` (`OpenApiSpex`) — требование ADR-0064.
- [x] README — строки опциональной зависимости `open_api_spex`: `Core.Web.Labels` → `Core.Web.Event`.
- [x] Свод: `docs/rules/app/15-web-api.md` — схема события — модуль с `use Core.Web.Event`, ручная схема события
      и страницы событий MUST NOT; `docs/rules/10-architecture.md` — образец условной схемы `Core.Web.Event`.
- [x] `CHANGELOG.md`, «Новое» — пункт о `Core.Web.Event` дополняется схемой; правка `app/**` — тем же коммитом.
- [x] `make` зелёный.
