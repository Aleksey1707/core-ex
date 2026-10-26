# 06: Дашборды `es` и `cache`

**What to build:** приложение выгружает дашборды подсистем библиотеки event sourcing (`es`) и
кеша (`cache`); оба входят в набор по умолчанию, когда в `plugins/0` есть `Core.Es.PromEx` /
`Core.Cache.PromEx`. Имена проекций и кешей приходят переменными дашборда. Основа — дашборды
потребителя A (`research.md`, раздел 1). Спека: `.scratch/consumer-tooling/spec.md`.

**Blocked by:** 01, 03

**Status:** ready-for-agent

- [ ] Шаблоны `es` и `cache` в `priv`, литералы под приложение — параметры
- [ ] Набор по умолчанию по `plugins/0`; тест на отсутствие без плагина
- [ ] Самопроверка: имена метрик объявлены `Core.Es.PromEx` / `Core.Cache.PromEx`, форма панелей проходит
- [ ] Пункт в CHANGELOG дополнен
- [ ] `make` зелёный
