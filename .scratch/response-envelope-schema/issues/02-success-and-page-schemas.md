# 02: Схемы успеха и страницы

**Status:** resolved

**Blocked by:** 01

**What to build:** `Response.Schema.success(data)`, `success()` и `page(item)` — анонимные схемы
обёртки успеха со схемой данных эндпоинта аргументом. Спека — `../spec.md`, user stories 1–3, 5, 7,
10–11; ADR-0065.

- [x] `success(data)` — `{status: enum ["ok"], data}`; `success()` — `data` объектом без свойств;
      `page(item)` — `data: {items: [item], total: integer ≥ 0}`; без названия и опции `title:`;
      `data` / `item` — модуль схемы, `%OpenApiSpex.Schema{}` или `%OpenApiSpex.Reference{}`.
- [x] Объекты открытые, `additionalProperties: false` нет.
- [x] Тест: `success/0,1` и `success(page_data(...))` после круга через JSON проходят свои схемы на
      фикстурной схеме элемента; тело ошибки против схемы успеха и страница без `total` — отказ.
- [x] Свод `docs/rules/app/15-web-api.md`, «Schemas»: схема обёртки, страницы и ошибки —
      `Core.Web.Response.Schema`, своя — MUST NOT (вместо «собираются общими хелперами»).
- [x] `CHANGELOG.md` — дополняется пункт схемы обёртки: было → стало для хелпера с анонимной
      схемой, хелпера с названием, модуля ответа на операцию и `allOf` над своим компонентом;
      правка `app/**` — тем же коммитом.
- [x] `make` зелёный.
