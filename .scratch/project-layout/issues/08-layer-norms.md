# 08: Нормы раскладки по слоям

**What to build:** на вопросы «куда класть X», на которые свод не отвечал, появляются ответы:
usecases, Prim, каталог ошибок, аксессор текущего пользователя, web, тесты, `config/`. Примеры
README и свода библиотеки называют модули так же, как ярус потребителя.

**Blocked by:** 01

**Status:** ready-for-agent

**Spec:** [Раскладка потребителя](../spec.md) — «Свод потребителя», «Свод библиотеки, README, CONTEXT»

- [ ] `app/10`, «Usecases»: `MyApp.Domain.<BC>.<Actor>.Usecases.<Scenario>`, по умолчанию имя
      агрегата.
- [ ] `app/10`: таблица «файл `config/` → что в нём» со ссылками на `app/14`, `app/16`, `app/17`,
      `app/19`, `app/21`; секреты и env в `dev.exs` / `prod.exs` — `MUST NOT`.
- [ ] `app/11`: Prim вложен в агрегат-владелец по имени, файл отдельный или внутри — `MAY`;
      значение без владельца — `<BC>.Common.<Value>`; аксессор текущего пользователя — пример в
      `Common` контекста, владеющего учётной записью. `11-domain.md` библиотеки — то же.
- [ ] `app/12`: путь каталога ошибок следует из «путь = имя»; обещание «пути» в своде библиотеки
      исправлено.
- [ ] `app/15`: поверхность `MyAppWeb.<Api>` с `ApiSpec` и `<Version>.<Resource>`; общее для
      поверхностей — в корне `MyAppWeb`, включая `Schemas`; вложенный ресурс — вложенный namespace.
- [ ] `app/19`: тест модуля — по пути модуля (`SHOULD`); архитектурный тест и ратчеты — в
      `test/my_app/`; `ConnCase` — в `test/support/`.
- [ ] README и `13-repos.md`: `MyApp.Domain.Orders.Order.Repo` и `<BC>.Common.Repo` →
      `MyApp.Domain.<BC>.Common.<Aggregate>.Repo`; `MyApp.Repo.Migrations.*` →
      `MyApp.DAO.Migrations.*`.
- [ ] CHANGELOG, «Ломающие изменения контракта»: usecases по сценарию и нормы слоёв, было → стало.
- [ ] `make rules-check` и `make` зелёные.
