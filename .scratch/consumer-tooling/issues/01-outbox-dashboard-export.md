# 01: Экспорт дашборда outbox — от шаблона до файла

**What to build:** приложение выполняет `mix core.dashboards.export --module MyAppApp.PromEx` и
получает в каталоге дашбордов выгрузку дашборда подсистемы библиотеки outbox. В выгрузке префикс
метрик, `title`, `uid` и datasource приложения, пороги стат-панелей — из `dashboard_assigns/0` его
модуля PromEx или умолчаний библиотеки. Тикет прокладывает колею для остальных шаблонов: модуль
`Core.PromEx.Dashboards` (рендер одного дашборда через `PromEx.DashboardRenderer`, набор по
умолчанию по `plugins/0` — пока только outbox), задача экспорта, самопроверка имён метрик.
Основа шаблона — дашборд outbox потребителя A (`research.md`, раздел 1), литералы под приложение
становятся параметрами. Спека: `.scratch/consumer-tooling/spec.md`; решение: ADR-0089.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] Шаблон EEx дашборда outbox лежит в `priv` библиотеки; рендер даёт валидный JSON
- [ ] Префикс, `title`, `uid`, `tags` строятся от `otp_app` и имени дашборда; datasource — параметр `datasource_id`, как у штатных дашбордов
- [ ] Пороги — параметры шаблона: умолчания библиотеки уступают `dashboard_assigns/0` приложения
- [ ] Публичный `Core.PromEx.Dashboards` с `@moduledoc` / `@doc` / `@spec`: рендер одного дашборда, набор по умолчанию по `plugins/0`
- [ ] `mix core.dashboards.export`: `--module` обязателен, `--dashboard` повторяемый, `--out` с умолчанием `deploy/monitoring/grafana/dashboards`; ответ через `Mix.shell()`
- [ ] Самопроверка: каждое имя метрики в запросах и переменных шаблона (после снятия префикса, с суффиксами distribution) объявлено плагином `Core.*.PromEx`
- [ ] Тест задачи во временном каталоге: набор по умолчанию, `--dashboard`, `--out`, отказ без `--module`
- [ ] Абзац об экспорте в `README.md`; пункт в CHANGELOG «Новое»
- [ ] `make` зелёный
