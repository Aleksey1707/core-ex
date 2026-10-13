# 01: Дамп события страницы событий

**Status:** resolved

**What to build:** модуль приложения с `use Core.Web.Event` (внешний профиль кодека `codec:`, необязательная
ссылка на учётную запись `user_ref: [dump:]`) получает `to_wire/2`: событие и словарь ссылок → map события
страницы событий для JSON. Без подписей и без схемы. Спека — `../spec.md`, «`use Core.Web.Event`», user
stories 1–3, 5–13; ADR-0066.

- [x] Опции: обязательная `codec:` — модуль с `dump/1`; необязательная `user_ref:` с `dump:` — захват функции
      «дамп id, имя → map» арности 2; иное — `CompileError` через `Core.Helper.Opts.validate!`.
- [x] `to_wire/2`: поля конверта (`codec.dump/1` → `Core.Es.Event.Codec.to_fields/1`) → `id`, `aggregateId`,
      `version`, `type`, `payload` (ключи — camelize, без подмены id), `at`, `by`.
- [x] `by`: без `user_ref:` — дамп id; с ним — `dump:` от дампа id и имени из словаря ссылок (`nil`-имя
      передаётся как есть); автора нет в словаре — `ArgumentError`.
- [x] Порождённая функция следует правилам генерируемых функций (`20-agreements.md`, ADR-0014).
- [x] Тесты: обе конфигурации, нагрузка `nil`, вложенная нагрузка (camelize на глубине), `by` с именем и
      `nil`, исключение на автора вне словаря, отказы сборки.
- [x] Фикстура-потребитель (без `open_api_spex`) объявляет модуль с `use Core.Web.Event`; `make consumer-check`
      зелёный.
- [x] Свод: `docs/rules/app/15-web-api.md` — дамп события страницы событий MUST через `use Core.Web.Event`,
      ручной презентер MUST NOT, точечная правка результата MAY; `docs/rules/10-architecture.md` — строка
      `Core.Web.Event` в таблице модулей `Core.Web.*`.
- [x] `CHANGELOG.md`, «Новое» — пункт о `Core.Web.Event` с «было → стало» для презентера события; правка
      `app/**` — тем же коммитом.
- [x] `make` зелёный.
