# 10: `Core.Web.Params` — строгая и необязательная версия `If-Match`

**Status:** needs-triage

**What to build:** формы разбора `If-Match` помимо `Version.expected()`: строгая (`*` запрещён — usecase
принимает только `%Version{}`) и необязательная (нет заголовка → `:current`), например опцией `current:`.

**Why:** `app/15-web-api.md`, «Controller» велит разбирать заголовок `Core.Web.Params.version/2`, а
приложение держит свой хелпер с двумя недостающими формами (десятки вызовов против двух вызовов библиотеки).

- [ ] функция и тесты; `app/15`, `10-architecture.md` «Граница HTTP»; CHANGELOG «Новое»
