# 01: Схема ошибки `ErrorResponse`

**Status:** resolved

**Blocked by:** —

**What to build:** условный модуль `Core.Web.Response.Schema` с `error()` и модулем
`Core.Web.Response.Schema.Error` (название `ErrorResponse`) — одна схема на все статусы ошибки.
Спека — `../spec.md`, user stories 4–6, 8–10; ADR-0065.

- [x] `Core.Web.Response.Schema` под `if Code.ensure_loaded?(OpenApiSpex)`; `make compile-no-optional`
      зелёный.
- [x] `ErrorResponse`: `status` — `enum ["error"]`, `code` — строка, `message` — строка, `data` —
      открытый объект с необязательным `errors: [{code, message}]`; пример — доменная ошибка с
      `data.errors`; не через `OpenApiSpex.schema/2`.
- [x] Тест: `Response.error/2,3` и каждая строка `Core.Web.ErrorMapper.map/2` (включая `Error.many`)
      после круга через JSON проходят `ErrorResponse`; пример проходит свою схему; `status: "ok"` и
      `code` числом — отказ.
- [x] Свод `docs/rules/10-architecture.md`, «OpenAPI-схемы wire», — уточнение: параметр
      приложения — опция `use`, схема данных места вызова — аргумент функции условного модуля;
      таблица «Граница HTTP» — строка `Core.Web.Response.Schema`.
- [x] README — `Core.Web.Response.Schema` в разделе об `open_api_spex` с оговоркой о пересборке
      `core`.
- [x] `CHANGELOG.md` — «Новое»: схема ошибки, было → стало для своего компонента ошибки.
- [x] `make` зелёный.
