# Инструменты потребителя A: дашборды Grafana / PromEx, Oban Web, Tidewave

Исследование кода потребителя A. Нужно, чтобы решить, что из этого станет нормой в `docs/rules/app/*.md`
и стоит ли core-ex поставлять инфраструктурные дашборды. Нормы здесь не формулируются.

Обозначения источников: `A: <путь>:<строка>` — файл потребителя A (обезличенный путь);
`deps/<пакет>/…` — исходник зависимости у A, версия по `A: mix.lock`; путь без префикса — core-ex.
Версии зависимостей у A: `prom_ex` 1.12.0 (`A: mix.lock:85`), `oban` 2.24.2 (`:57`), `oban_met` 1.3.3
(`:58`), `oban_web` 2.13.1 (`:59`), `phoenix_live_view` 1.2.12 (`:78`), `tidewave` 0.9.1 (`:103`).
Сейчас `:core` подключён у A path-зависимостью (`A: mix.exs:57`), а в `mix.lock` записан тег v0.15.1
(`A: mix.lock:15`). Имена метрик сверялись с текущим HEAD core-ex.

## Резюме

1. В A 13 дашбордов. 5 из них — копии штатных дашбордов PromEx (application, beam, phoenix, ecto,
   oban), 8 — свои. Четыре копии совпадают с отрендеренным шаблоном PromEx 1.12.0 байт в байт (после
   нормализации JSON). `beam.json` доработан: в него добавлена панель памяти контейнера
   `Core.Cgroup.PromEx` с порогами.
2. Свои дашборды почти целиком инфраструктурные: `outbox`, `mq` (RabbitMQ Stream), `kafka`, `es`,
   `cache`, `workers` строятся на метриках `Core.*.PromEx`, а `infra` — на экспортёрах Postgres,
   RabbitMQ и хоста. Чисто доменных дашбордов нет. Доменные панели вкраплены в три дашборда: `workers`
   (3 панели), `storage` (1 доменная панель, остальное — `Core.External.PromEx`) и `mq` (1 панель
   собственного плагина приложения).
3. Как есть дашборды из библиотеки поставить нельзя. Жёстко прописаны: префикс `<otp_app>_prom_ex_`
   в каждом запросе и каждой переменной, имя приложения в `title`, `uid` и `tags`, uid datasource
   `prometheus` (строкой), значения `system=` внешних систем, `job="rabbitmq"` и пороги. Имён очередей,
   проекций и топиков в JSON нет: они приходят переменными через `label_values`.
4. Grafana получает дашборды только provisioning'ом файлов (compose + `provisioning/*.yml`). Upload
   PromEx выключен (`grafana: :disabled`). `metric_prefix` нигде не задан и выводится из `otp_app`.
   Свод core-ex это и требует. Но `dashboards/0` у A по-прежнему перечисляет штатные дашборды, хотя
   их читает только uploader, а `beam.json` разошёлся с `{:prom_ex, "beam.json"}`.
5. У A есть собственная норма «Форма панелей» (растущие метки, легенды, переменные) с ратчетом
   `dashboards_test.exs`. В `DEBT.md` A прямо записано, что норма принадлежит ярусу
   `docs/rules/app/21-observability.md` core-ex. Имена метрик в дашбордах ратчетом не сверяются;
   сверяются только в алертах.
6. Oban Web смонтирован на отдельном Phoenix-эндпоинте на своём порту (4001, путь `/obanui`), а не в
   основном роутере. Причина: у приложения нет аутентификации, а дашборд меняет задачи. Логин и пароль
   спрашивает обратный прокси. Тумблер — `OBAN_DASHBOARD_ENABLED`, по умолчанию `true` (dev/prod), в
   test выключен. Резолвер штатный, доступ `:all`, read-only нет.
7. `Oban.Met` запускается вручную ребёнком корня дашборда (`config :oban_met, auto_start: false`),
   поэтому выключенный дашборд не опрашивает `oban_jobs`. Это документированный ручной путь
   `Oban.Met.start_link(conf:)`. Остальное — штатные опции `oban_dashboard`. Нештатное: `secret_key_base`
   генерируется случайно на каждом старте. Это годится для одной ноды и ломается за балансировщиком с
   несколькими нодами (не подтверждено проверкой).
8. Tidewave подключён ровно по README пакета: `plug Tidewave` под `if Mix.env() == :dev` выше блока
   `code_reloading?`, `only: :dev`, без опций. Используется как MCP-сервер для агента: `.mcp.json`,
   хук `SessionStart`, инструменты `project_eval`, `execute_sql_query`, `get_logs`. В релиз не попадает.
9. В своде core-ex нет ни Oban Web, ни Tidewave, ни правила обращения со штатными дашбордами PromEx.

## 1. Дашборды Grafana / PromEx

### 1.1 Доставка в Grafana

| Что | Как у A | Источник |
|---|---|---|
| Способ | provisioning файлами: каталог `dashboards/` монтируется в контейнер Grafana, провайдер `type: file` | `A: deploy/monitoring/compose.yml:57-68`, `A: deploy/monitoring/grafana/provisioning/dashboards/dashboards.yml:1-13` |
| Upload API PromEx | выключен: `grafana: :disabled`, `metrics_server: :disabled` | `A: config/config.exs:64-69` |
| `dashboards/0` | 5 штатных `{:prom_ex, "<name>.json"}` | `A: lib/app_a_app/prom_ex.ex:47-55` |
| Кто читает `dashboards/0` | только uploader PromEx, а он выключен | `deps/prom_ex/lib/prom_ex/dashboard_uploader.ex:60` |
| `dashboard_assigns/0` | `datasource_id: "prometheus"`, `default_selected_interval: "30s"` | `A: lib/app_a_app/prom_ex.ex:38-43` |
| Datasource | Prometheus `uid: prometheus` (комментарий: «uid обязан совпадать с datasource_id»), Tempo `uid: tempo` | `A: deploy/monitoring/grafana/provisioning/datasources/datasource.yml:4-19` |
| `metric_prefix` | не задан ни у одного плагина: по умолчанию `PromEx.metric_prefix(otp_app, <плагин>)` → `<otp_app>_prom_ex_<плагин>_…`, `otp_app` — из `use PromEx` | `A: lib/app_a_app/prom_ex.ex:6`, `lib/core/outbox/prom_ex.ex:22`, `deps/prom_ex/lib/prom_ex/dashboard_renderer.ex:162-178` |
| Скрейп | job с именем приложения → `app:9568`; `postgres` → postgres_exporter; `rabbitmq` → `rabbitmq:15692`; `node` → node_exporter (профиль `host-metrics`) | `A: deploy/monitoring/prometheus/prometheus.yml:13-37`, `A: deploy/monitoring/compose.yml:110-148` |
| Экспортёр Kafka-брокера | нет: дашборд `kafka` строится только на метриках читателя `Core.Mq.PromEx` | `A: deploy/monitoring/prometheus/prometheus.yml:13-37` |

В панелях datasource записан строкой `"datasource": "prometheus"` (например,
`A: deploy/monitoring/grafana/dashboards/es.json:37`), `schemaVersion: 26`. Это унаследованная форма
шаблонов PromEx. Что Grafana разрешает такую строку по uid, а не только по имени, подтверждает лишь
комментарий A (`datasource.yml:4`); по первоисточнику Grafana не проверено.

### 1.2 Перечень дашбордов

| Файл | Вид | Источник метрик | Хардкоды, мешающие поставке из библиотеки |
|---|---|---|---|
| `application.json` | штатный PromEx, без правок | `PromEx.Plugins.Application` | `title` и `uid` содержат имя приложения; префикс `<otp_app>_prom_ex_` |
| `beam.json` | штатный PromEx, **доработан** | `PromEx.Plugins.Beam` + `Core.Cgroup.PromEx` (`cgroup_memory_current_bytes`) | то же, плюс пороги панели контейнера 500 МБ / 1 ГБ (`beam.json:947-1000`) |
| `phoenix.json` | штатный PromEx, без правок | `PromEx.Plugins.Phoenix` | как у application |
| `ecto.json` | штатный PromEx, без правок | `PromEx.Plugins.Ecto` | как у application |
| `oban.json` | штатный PromEx, без правок | `PromEx.Plugins.Oban` | как у application |
| `outbox.json` | свой, инфраструктурный | `Core.Outbox.PromEx` | префикс, `title`/`uid`/`tags` с именем приложения, пороги стат-панелей |
| `mq.json` | свой, инфраструктурный + 1 панель приложения | `Core.Mq.PromEx` (stream) + собственный плагин приложения `<otp_app>_prom_ex_subscriber_lost_total` (`mq.json:442`, `:551`) | префикс, `title`/`tags` |
| `kafka.json` | свой, инфраструктурный | `Core.Mq.PromEx` (kafka, dlq) | префикс, `title`/`uid`/`tags` (`kafka.json:24-44`); DLQ-панели требуют `dlq_repo:` у плагина |
| `es.json` | свой, инфраструктурный | `Core.Es.PromEx` | префикс, `title`/`uid` (`es.json:1481-1482`) |
| `cache.json` | свой, инфраструктурный | `Core.Cache.PromEx` | префикс, `title`/`uid` (`cache.json:111-112`); имена кешей — переменной |
| `workers.json` | свой, смешанный | `Core.Workers.PromEx` + счётчики сбоев сбора всех плагинов `Core.PromEx.Safe` + 3 доменные панели | префикс (в том числе в регулярке `{__name__=~"<otp_app>_prom_ex_.+_collect_errors_total"}`, `workers.json:474`), описание со ссылкой на модуль приложения (`workers.json:15`, `:389`) |
| `storage.json` | свой, смешанный, ближе к доменному | `Core.External.PromEx` с литералами `system="<внешняя система>"` для двух систем (`storage.json:93` и др.) + 1 доменная панель | префикс, литералы `system=`, описание со ссылкой на модуль приложения (`storage.json:15`) |
| `infra.json` | свой, инфраструктура окружения | postgres_exporter (`pg_*`), RabbitMQ (`rabbitmq_*`, `up{job="rabbitmq"}`), node_exporter (`node_*`) | нет переменных `job`/`instance` вообще (`templating: []`); `up{job="rabbitmq"}` (`infra.json:408`); запросы без фильтра (`pg_up`, `infra.json:136`) склеят все экземпляры общего Prometheus |

Доменных дашбордов (целиком на метриках собственных плагинов приложения) нет: 0. Доменные панели —
внутри смешанных дашбордов: `workers` (3), `storage` (1).

Собственные плагины A: три доменных и провайдер размеров кешей для `Core.Cache.PromEx`
(`A: lib/app_a_app/prom_ex.ex:26`, `:30-32`). Один из доменных — счётчик потерь подписчиков
(`<otp_app>_prom_ex_subscriber_lost_total`) — по смыслу инфраструктурный: он считает пропуски у
подписчиков MQ (`A: lib/app_a_app/prom_ex/subscribers.ex:1-12`).

### 1.3 Как сравнивались штатные копии

Шаблоны `deps/prom_ex/priv/{application,beam,phoenix,ecto,oban}.json.eex` отрендерены через
`EEx.eval_string` с теми же assigns, что даёт PromEx: умолчания `default_plugin_assigns/1`
(`deps/prom_ex/lib/prom_ex/dashboard_renderer.ex:162-178`), `dashboard_assigns/0` A, а также `title` и
`uid` из файла A. Затем JSON сравнивался после нормализации (сортировка ключей).

- `application`, `phoenix`, `ecto`, `oban` — идентичны. Скорее всего, получены
  `mix prom_ex.dashboard.export` (`deps/prom_ex/lib/mix/tasks/prom_ex.dashboard.export.ex:106-131`).
  Что именно этой командой — не подтверждено.
- `beam` — 82 строки диффа. Панель «Total Memory Usage» сужена (`w` 6 → 3) и переименована в «BEAM
  Memory». Добавлена stat-панель «Container Memory» на `<otp_app>_prom_ex_cgroup_memory_current_bytes`
  с порогами 500 МБ / 1 ГБ. В график памяти добавлена серия «Container» (`A: …/beam.json:947`, `:997`,
  `:1194`).
- `title` штатных копий имеют вид `<APP> - PromEx <Name> Dashboard` с аббревиатурой приложения в
  верхнем регистре. Экспорт по умолчанию дал бы `Macro.camelize(otp_app)` (`export.ex:109-123`), так
  что `title` задан вручную или через `--assign` (не подтверждено). `uid` — MD5 от otp_app, модуля,
  пути и заголовка (`deps/prom_ex/lib/prom_ex.ex:311-319`), то есть он зависит от приложения.

Повторный экспорт `beam.json` молча сотрёт панель cgroup: правка нигде не задокументирована, а
`dashboards/0` по-прежнему ссылается на штатный `beam.json` (`A: lib/app_a_app/prom_ex.ex:50`).

### 1.4 Метрики инфраструктурных дашбордов и их плагины в core-ex

Префикс опущен: везде `<otp_app>_prom_ex_`.

| Дашборд | Метрики в запросах | Плагин core-ex |
|---|---|---|
| outbox | `outbox_queue_count`, `outbox_queue_oldest_age_seconds`, `outbox_queue_expired_locks_count`, `outbox_delivery_total`, `outbox_poller_{published,retry,failed,cycles}_total`, `outbox_poller_duration_milliseconds_bucket`, `outbox_poller_batch_size`, `outbox_cleaner_{deleted,cycles}_total` | `lib/core/outbox/prom_ex.ex:31-104`, `:131-144` |
| mq | `mq_publish_total`, `mq_publish_duration_milliseconds_bucket`, `mq_deliver_entries_total`, `mq_decode_drop_total`, `mq_subscriber_cycles_total`, `mq_reader_{buffer_len,chunk_remaining,pending}` | `lib/core/mq/prom_ex.ex:82-131`, `:261-277` |
| kafka | `mq_kafka_reader_{lease,lag_messages,lag_seconds}`, `mq_kafka_{read_errors,commit_errors,offset_reset,decode_drop}_total`, `mq_subscriber_dlq_total`, `mq_dlq_count` | `lib/core/mq/prom_ex.ex:138-171`, `:361-379`, `:466` (`dlq_repo:` — `:42`) |
| es | `es_projection_{lag_seconds,rebuilding,outdated}`, `es_projection_{cycles,retry,events,await}_total`, `es_projection_duration_milliseconds_bucket`, `es_projection_await_duration_milliseconds_bucket`, `es_checkpoint_orphan`, `es_aggregate_load_total`, `es_aggregate_load_duration_milliseconds_bucket`, `es_aggregate_fold_events_bucket`, `es_key_reservation_total` | `lib/core/es/prom_ex.ex:113-163`, `:204-242`, `:360-381` |
| cache | `cache_requests_total`, `cache_size` | `lib/core/cache/prom_ex.ex:31`, `:58` |
| workers (часть Core) | `workers_up`, `workers_message_queue_len`, `workers_memory_bytes`; `<плагин>_collect_errors_total` | `lib/core/workers/prom_ex.ex:54-70`; `lib/core/prom_ex/safe.ex:90-92` |
| storage (часть Core) | `external_call_total`, `external_call_duration_milliseconds_bucket` | `lib/core/external/prom_ex.ex:36`, `:46` |
| beam (доработка) | `cgroup_memory_current_bytes` | `lib/core/cgroup/prom_ex.ex:39` |

Переменные всех своих дашбордов, кроме `infra`: `job` и `instance` из
`label_values(<otp_app>_prom_ex_prom_ex_status_info, job)` (например, `A: …/es.json:1382-1389`), плюс
переменная растущей метки (`projection`, `type`, `topic`, `component`, `cache`, `subscriber`).

Метрики core-ex, которых нет ни на одном дашборде A: `es_snapshot_write_*`, `es_personal_*`,
`es_projection_signal_*`, `es_aggregate_process_*`, `es_aggregate_processes`
(`lib/core/es/prom_ex.ex:139-187`, `:252-318`, `:404`), `mq_kafka_publish_*`,
`mq_reader_pending_age_seconds`, `mq_reader_subscribed` (`lib/core/mq/prom_ex.ex:99-106`, `:285-295`),
`outbox_cleaner_duration_*` (`lib/core/outbox/prom_ex.ex:94`), `cgroup_memory_{anon,max}_bytes`
(`lib/core/cgroup/prom_ex.ex:45-51`). У A нет процессов агрегата и ПДн-событий (подтверждено только
для процессов: `A: docs/rules/17-otp-concurrency.md:32`).

### 1.5 Алерты (для контекста)

- `rules/<app>.yml` содержит 46 правил, `rules/infra.yml` — 10. Тесты `promtool` лежат в
  `deploy/monitoring/prometheus/tests/` и запускаются из `Makefile` (`A: Makefile:83-88`).
- 41 из 46 правил приложения стоят на метриках `Core.*.PromEx` (37: outbox, workers, mq, cache, es,
  external, cgroup) или штатных плагинов PromEx (4: phoenix, ecto, oban). Ещё 2 доменных, 1 на
  счётчике подписчиков и 2 общих: `AppDown` на `up{job="<app>"}` (`A: …/rules/<app>.yml:5`) и
  `PromExCollectFailing`.
- Действие оператора у всех 46 записано отдельным ключом `runbook:` (например,
  `A: …/rules/<app>.yml:593`).
- Ратчет `A: test/app_a_app/prom_ex/alerts_test.exs:1-20` сверяет имена метрик в правилах с тем, что
  объявляют плагины (`PromEx.init_plugins/3`). Для дашбордов такой сверки нет: `dashboards_test.exs`
  проверяет только форму панелей (`A: test/app_a_app/prom_ex/dashboards_test.exs:1-16`, `:35-44`).

### 1.6 Сервер метрик

| Что | Как у A | Источник |
|---|---|---|
| Сервер | свой Supervisor + Bandit, плаг `Core.Web.MetricsPlug` | `A: lib/app_a_app/metrics_server.ex:74-80` |
| Почему не штатный `metrics_server` PromEx | он поднимает `Plug.Cowboy`, а приложение работает на Bandit | `A: lib/app_a_app/metrics_server.ex:8-9` |
| Тумблер | `METRICS_SERVER_ENABLED` (умолчание `true`); в test `enabled: false` и PromEx `disabled: true` | `A: config/runtime.exs:149-153`, `A: config/test.exs:103-105` |
| Адрес | `ip:` = `{0,0,0,0}` только в prod, иначе `{127,0,0,1}` | `A: config/runtime.exs:145-147` |
| Порт / путь | 9568 / `METRICS_SERVER_PATH` (умолчание `/metrics`); на хост не публикуется | `A: config/runtime.exs:139`, `:152`; `A: deploy/full/compose.yml:27-29` |
| Трассировка скрейпа | путь метрик исключён из корневых span'ов сэмплером | `A: config/runtime.exs:141-143` |

## 2. Oban Web

### 2.1 Устройство

| Что | Как у A | Источник |
|---|---|---|
| Корень | `AppAApp.ObanDashboard` (Supervisor) в дереве после `Core.Es.Projection.Supervisor`, контекстов и `AppAApp.MetricsServer`, перед основным эндпоинтом | `A: lib/app_a_app/application.ex:53-56` |
| Эндпоинт | отдельный `AppAApp.ObanDashboard.Endpoint` (`use Phoenix.Endpoint`): `Plug.Session` + роутер; конфигурация передаётся опциями старта, ключа в `config` нет | `A: lib/app_a_app/oban_dashboard/endpoint.ex:1-29` |
| Опции эндпоинта | `adapter: Bandit.PhoenixAdapter`, `url: [host: host]`, `http: [ip:, port:]`, `server: true`, случайный `secret_key_base`, `live_view: [signing_salt: …]`, `pubsub_server: AppA.PubSub`, `render_errors` → текстовый `ErrorHTML` | `A: lib/app_a_app/oban_dashboard.ex:85-97`, `A: lib/app_a_app/oban_dashboard/error_html.ex:1-8` |
| Роутер | `pipeline :browser` (`accepts html`, `fetch_session`, `protect_from_forgery`, `put_secure_browser_headers`) → `oban_dashboard "/obanui", socket_path: "/obanui/live"` | `A: lib/app_a_app/oban_dashboard/router.ex:10-21` |
| Сессия | cookie, ключ `_app_a_oban_dashboard`, `signing_salt` литералом, `same_site: "Lax"`; хранит только CSRF-токен LiveView | `A: lib/app_a_app/oban_dashboard/endpoint.ex:16-21`; `A: lib/app_a_app/oban_dashboard.ex:10-11` |
| LiveView-сокет | `socket "/obanui/live", Phoenix.LiveView.Socket`, `connect_info: [session: …]`, `longpoll: false`; страница, ассеты и сокет лежат под одним префиксом `/obanui`, чтобы прокси хватило одного `location` | `A: lib/app_a_app/oban_dashboard/endpoint.ex:23-25`; `A: lib/app_a_app/oban_dashboard.ex:8` |
| `check_origin` | по умолчанию: Origin сверяется с `url: [host:]` = `OBAN_DASHBOARD_HOST`. `:conn` не используется, потому что от DNS rebinding он не защищает | `A: lib/app_a_app/oban_dashboard/endpoint.ex:9-11`; `A: docs/rules/17-otp-concurrency.md:182-183` |
| Порт / адрес | `OBAN_DASHBOARD_PORT` (4001); `ip:` = `{0,0,0,0}` только в prod, иначе loopback; в full-compose проброшен только на `127.0.0.1` хоста | `A: config/runtime.exs:145-159`; `A: deploy/full/compose.yml:24-26` |

Почему отдельный эндпоинт: «аутентификации у приложения нет, а дашборд отменяет, удаляет и
перезапускает задачи». Порт наружу не публикуется, в prod к нему ходит только обратный прокси с логином
и паролем (`A: lib/app_a_app/oban_dashboard.ex:5-8`; `A: docs/rules/17-otp-concurrency.md:169-177`).
Пример `nginx` с `auth_basic` и upgrade до websocket есть только в документации A
(`A: docs/rules/17-otp-concurrency.md:184-196`). Конфигурации прокси в `deploy/` нет.

### 2.2 Тумблер

- Env-ключ `OBAN_DASHBOARD_ENABLED`, по умолчанию `"true"`. Задаётся в `config/runtime.exs` вне test,
  то есть для dev и prod (`A: config/runtime.exs:145`, `:155-156`).
- В test — `enabled: false` (`A: config/test.exs:107`).
- Выключенный корень отвечает `:ignore` с `info` «Дашборд Oban отключён». Эндпоинт и `Oban.Met` не
  стартуют, `oban_jobs` никто не опрашивает (`A: lib/app_a_app/oban_dashboard.ex:66-72`, `:107-111`;
  `A: config/config.exs:57-59`).
- Цена выключения: «очереди и задачи видны и правятся только через `iex`»
  (`A: docs/rules/17-otp-concurrency.md:54`).
- Схема конфигурации — NimbleOptions; неизвестный ключ даёт `ArgumentError`
  (`A: lib/app_a_app/oban_dashboard.ex:27-53`, `:113-117`; тест
  `A: test/app_a_app/oban_dashboard_test.exs:33-39`).

### 2.3 Доступ

- Резолвер не задан, используется штатный `Oban.Web.Resolver`: `resolve_user → nil`,
  `resolve_access → :all` (`deps/oban_web/lib/oban/web/resolver.ex:16-22`,
  `deps/oban_web/lib/oban/web/router.ex:130-133`).
- Read-only нет: «Доступ внутри дашборда полный (резолвер по умолчанию)»
  (`A: docs/rules/17-otp-concurrency.md:171-172`). Штатно доступны `:read_only` и `{:forbidden, path}`
  (`deps/oban_web/lib/oban/web/resolver.ex:138`, `:317-370`).
- Защита — только сеть (loopback / закрытая сеть контейнеров), basic auth на прокси и проверка Origin
  сокета.

### 2.4 Сборщик метрик `Oban.Met`

- У `oban_met` по умолчанию `auto_start: true`, `auto_testing_modes: [:disabled]`
  (`deps/oban_met/mix.exs:37`). Автостарт цепляется за `[:oban, :supervisor, :init]` и поднимает Met
  под своим супервизором (`deps/oban_met/lib/oban/met/application.ex:15-65`).
- A выключает автостарт (`A: config/config.exs:57-59`) и ставит `{Oban.Met, conf: conf}` ребёнком
  корня дашборда, только если `Oban.config(Oban).testing == :disabled`. Так повторяется условие
  автостарта (`A: lib/app_a_app/oban_dashboard.ex:13-15`, `:86`, `:104-105`).
- Причина: автостарт «опрашивал бы `oban_jobs` раз в секунду и при выключенном дашборде»
  (`A: lib/app_a_app/oban_dashboard.ex:13-15`).
- Это штатно: README `oban_met` описывает `auto_start: false` и ручной старт плагином Oban
  (`deps/oban_met/README.md:126-150`). `Oban.Met.start_link/1` документирован как ручной старт при
  выключенном автостарте (`deps/oban_met/lib/met.ex:56-80`). A выбрал ребёнка своего корня, а не
  плагин в `plugins:` Oban. Плагином тумблер дашборда Met бы не выключал.
- Чем A отличается от автостарта: тот следит за процессом Oban и снимает Met при его падении
  (`deps/oban_met/lib/oban/met/application.ex:67-82`). У A Met под отдельным корнем `:one_for_one`.
  Как он ведёт себя после рестарта `Oban` — не подтверждено.
- В test страницу дашборда не смонтировать (у Oban с `testing: :manual` нет Met), поэтому тест
  проверяет маршруты по ассету `/obanui/fonts/inter.woff2` (`A: test/app_a_app/oban_dashboard_test.exs:20-31`).

### 2.5 Зависимости и релиз

- `{:oban_web, "~> 2.13"}` (`A: mix.exs:76`). `oban_web` 2.13.1 требует `phoenix ~> 1.7`, `phoenix_html`,
  `phoenix_pubsub`, `phoenix_live_view ~> 1.0`, `oban ~> 2.24`, `oban_met ~> 1.1`
  (`deps/oban_web/mix.exs:97-105`).
- `phoenix_live_view` объявлен у A явно, но по другой причине (HEEx-шаблон), а не ради Oban Web
  (`A: mix.exs:88-89`).
- Ассеты самодостаточны: CSS, JS (вместе с JS Phoenix и LiveView) и шрифт вшиваются в модуль
  `Oban.Web.Assets` при компиляции из `priv/static` (`deps/oban_web/lib/oban/web/assets.ex:8-35`) и
  отдаются маршрутами `oban_dashboard` (`deps/oban_web/lib/oban/web/router.ex:199-202`). CSRF для
  ассетов пропускается (`assets.ex:58`). Ни esbuild, ни `phx.digest` релизу не нужны. Документация
  подтверждает: «doesn't hook into your asset pipeline at all»
  (https://oban-web.hexdocs.pm/2.13.1/installation.html).

### 2.6 Сверка с документацией Oban Web 2.13.1

| Аспект | Документация | A | Оценка |
|---|---|---|---|
| Монтирование | `oban_dashboard "/oban"` в `scope "/"` с `pipe_through :browser`; через igniter — в `:dev_routes` (installation.html) | `oban_dashboard "/obanui"` в своём роутере за `:browser` | штатно |
| `socket_path:` | опция, умолчание `"/live"` (`deps/oban_web/lib/oban/web/router.ex:162`) | `"/obanui/live"` | штатно |
| Отдельный эндпоинт / порт | не описан (installation.html); альтернатива — отдельный Docker-образ `oban-dash` (`deps/oban_web/README.md:77-89`) | свой `Phoenix.Endpoint` на отдельном порту | своё решение на штатных средствах Phoenix |
| Ограничение доступа | Basic Auth или `Oban.Web.Resolver`; `on_mount` (`router.ex:55-62`) | basic auth на внешнем прокси, резолвер штатный | своё решение: защита вынесена из приложения |
| `secret_key_base` | не описан | случайный на старте | обход. Для нескольких нод за балансировщиком без sticky-сессий токены сессии не сойдутся (вывод из кода, не подтверждено) |
| Метрики | `Oban.Met` нужен; на раздельных web/worker нодах — зависимость на worker'ах; для точности — PG-нотифаер и кластер (installation.html) | ручной старт под корнем дашборда, одна нода (`A: config/config.exs:61-62`) | штатно (документированный ручной путь) |

## 3. Tidewave

### 3.1 Подключение

- Зависимость `{:tidewave, "~> 0.9.1", only: :dev}` (`A: mix.exs:113`).
- В основном эндпоинте `if Mix.env() == :dev do plug Tidewave end`, после `Plug.Static` и до блока
  `if code_reloading?`. Опций нет, порт отдельно не выделен (`A: lib/app_a_web/endpoint.ex:21-23`).
- Своего `config :tidewave` нет. В `config/dev.exs` Tidewave упоминается только в комментарии к
  файловому логу (`A: config/dev.exs:55-63`).
- Dev-эндпоинт слушает только loopback (`A: config/dev.exs:20-22`) и имеет `check_origin: false`
  (`A: config/dev.exs:23`). Последнее касается сокетов Phoenix, не Tidewave.

### 3.2 Для чего

- MCP-сервер для агента. `.mcp.json` объявляет `http://localhost:${PORT:-4000}/tidewave/mcp`
  (`A: .mcp.json:1-8`). Хук `SessionStart` в `.claude/settings.json` проверяет доступность `curl` и
  просит пользователя поднять `make server` (`A: .claude/settings.json:8-19`).
- Документация A:
  - `README.md:29-30` — «сервер запускается до сессии агента»;
  - `AGENTS.md:165` — «Код и SQL в запущенном dev-узле — Tidewave»;
  - `docs/rules/17-otp-concurrency.md:74-85` — инструменты `project_eval`, `execute_sql_query`,
    `get_logs`; запрет второго узла рядом с сервером: он поднял бы второе дерево, а
    `AppAApp.ObanDashboard` и `AppAApp.MetricsServer` упали бы на `eaddrinuse`.
- Запасной канал — копия лога без цвета в `tmp/dev.log` на случай, когда Tidewave недоступен
  (`A: config/dev.exs:55-63`).

### 3.3 Сверка с документацией tidewave 0.9.1

| Аспект | Первоисточник | A | Оценка |
|---|---|---|---|
| Установка | `only: :dev`; `if Mix.env() == :dev do plug Tidewave end` прямо над `if code_reloading?` (`deps/tidewave/README.md:24-41`) | дословно так | штатно. Вариант `Code.ensure_loaded?` не нужен: при `MIX_ENV=prod` плаг не компилируется, релиз зависимость не тянет |
| Порядок плагов | плаг падает, если тело запроса уже разобрано или включён live reload (`deps/tidewave/lib/tidewave.ex:71-78`) | до `Plug.Parsers` и `CodeReloader` | штатно |
| Удалённый доступ | только localhost, иначе 403; `allow_remote_access: false` по умолчанию (`deps/tidewave/lib/tidewave.ex:32`, `deps/tidewave/lib/tidewave/router.ex:97-118`) | опция не задана | штатно. В контейнере (не на хосте) `remote_ip` не loopback, и MCP ответит 403 |
| Origin | `/mcp` с заголовком Origin отклоняется; `/ws`, `/upload` сверяются с хостом эндпоинта или `allowed_origins` (`router.ex:120-151`) | опция не задана | штатно |
| Prod | «Tidewave is a development tool and it must not be enabled in production» (https://tidewave.hexdocs.pm/security.html, v0.9.1) | только dev | штатно |
| Что даёт агенту | `project_eval`, `execute_sql_query`, `get_logs`, `get_source_location`, `get_docs`, `browser_eval`, `create_design_canvas` (`deps/tidewave/lib/tidewave/mcp/tools/*.ex`) | используются первые три | — |
| Тулбар | `toolbar: true` по умолчанию: в HTML-ответы dev вставляется скрипт с `tidewave.ai`, CSP переписывается (`unsafe-eval`, снимается `frame-ancestors`, `x-frame-options` удаляется) (`deps/tidewave/lib/tidewave.ex:37`, `:60-69`, `:88-132`; `deps/tidewave/README.md:157-159`) | опция не задана; API отдаёт JSON, HTML редок | подводный камень только для HTML-приложений: dev-CSP отличается от prod |
| Логи | приложение `:tidewave` стартует в dev (`mod:`) и ставит свой log handler (`deps/tidewave/mix.exs:28`, `deps/tidewave/lib/tidewave/mcp/logger.ex:24`) | — | видно в каждом dev-узле, в том числе `iex -S mix` |

Риски, которые называет первоисточник: код и SQL выполняются с правами разработчика против dev-базы,
и «Commands that execute code may perform any action on your machine»
(https://tidewave.hexdocs.pm/security.html, v0.9.1).

## Расхождения со сводом core-ex

| # | Свод core-ex | A | Вид |
|---|---|---|---|
| 1 | `docs/rules/app/21-observability.md:91-95`: дашборды провижнятся файлами, правка UI экспортируется в json | соблюдено. Но про штатные дашборды PromEx свод молчит: A держит их копии файлами, одну доработал (`beam.json`), а `dashboards/0` перечисляет штатные имена, которые никто не читает (`A: lib/app_a_app/prom_ex.ex:47-55`) | пробел свода |
| 2 | нормы «Форма панелей» в `docs/rules/app/21-observability.md` нет | у A она в локальном своде с ратчетом (`A: docs/rules/21-observability.md:116-149`), а `A: docs/rules/DEBT.md:65-71` прямо называет её нормой яруса core-ex, ждущей релиза | заявка потребителя в свод |
| 3 | `docs/rules/app/21-observability.md:95`: новая метрика приходит вместе с дашбордом; сверки имён нет | A сверяет имена метрик ратчетом только в алертах (`A: test/app_a_app/prom_ex/alerts_test.exs:1-20`), а в дашбордах нет | пробел (опечатка в дашборде молчит) |
| 4 | `docs/rules/app/21-observability.md:79-87`: отдельный сервер, `Core.Web.MetricsPlug`, в test выключен | соблюдено. Сверх свода: адрес `ip:` loopback / `0.0.0.0` только в prod (`A: config/runtime.exs:145-147`), причина «Bandit, а не Cowboy» (`A: lib/app_a_app/metrics_server.ex:8-9`) | кандидат в свод |
| 5 | `README.md:476-488`: пример `plugins/0` | A добавляет `dlq_repo:` у `Core.Mq.PromEx` (без него пусты DLQ-панели `kafka.json`) и `Core.External.PromEx`; `processes:` не задаёт (процессов агрегата нет) (`A: lib/app_a_app/prom_ex.ex:19-29`) | пример README неполон для дашборда Kafka |
| 6 | `docs/rules/app/21-observability.md:27-30`: префикс `<otp_app>_prom_ex_`, менять MUST NOT | соблюдено; `metric_prefix:` не используется | — |
| 7 | `docs/rules/app/21-observability.md:96-98`: действие оператора — отдельным ключом `annotations` | соблюдено: `runbook:` у всех 46 правил | — |
| 8 | `docs/rules/app/00-index.md:67`: «дашборды» отнесены к локальному своду приложения | у A инфраструктурные дашборды повторяют плагины core-ex один в один и для другого потребителя отличались бы только префиксом и `title`/`uid` | вопрос к границе ярусов (см. открытые вопросы) |
| 9 | Oban Web, `Oban.Met`, Tidewave в своде не упоминаются (grep по `docs/rules`, `README.md`, `docs/adr`) | у A есть нормы в локальном своде (`A: docs/rules/17-otp-concurrency.md:54`, `:74-85`, `:169-196`) | пробел свода |

## Открытые вопросы

1. **Поставлять ли инфраструктурные дашборды из core-ex.** Кандидаты: `outbox`, `mq` (stream),
   `kafka`, `es`, `cache`, Core-часть `workers` (вместе со счётчиком сбоев сбора), обобщённый
   `external` с переменной `system` вместо литерала, панель `cgroup`. Что придётся параметризовать:
   - префикс метрик `<otp_app>_prom_ex_` — во всех запросах и переменных, включая регулярку
     `__name__=~`;
   - `title`, `uid`, `tags` (сейчас содержат имя приложения);
   - uid datasource;
   - пороги стат-панелей (outbox, cgroup);
   - литералы `system=` (сделать переменной).

   `job` и `instance` уже идут переменными.
2. **Механизм поставки.** PromEx умеет рендерить EEx-дашборд из `priv` любого OTP-приложения
   (`{:core, "<path>.json.eex"}`, `deps/prom_ex/lib/prom_ex/dashboard_renderer.ex:42-73`), но только
   через upload API. Задача `mix prom_ex.dashboard.export` жёстко берёт `:prom_ex`
   (`deps/prom_ex/lib/mix/tasks/prom_ex.dashboard.export.ex:126`), а свод требует provisioning
   файлами. Варианты:
   - своя mix-задача core-ex для рендера в `deploy/monitoring/grafana/dashboards/`;
   - статический JSON с переменной Grafana для префикса;
   - разрешить upload.

   Какой выбрать — решать людям. Переменная в имени метрики в Grafana не проверена.
3. **Доменные панели в инфраструктурных дашбордах.** У A они смешаны (`workers`, `storage`, `mq`).
   Поставка из библиотеки потребует отделить их или дать потребителю точку расширения. Отдельный
   вопрос — не перенести ли счётчик потерь подписчика (`subscriber_lost_total`) в `Core.Mq.PromEx`:
   по смыслу он инфраструктурный.
4. **Штатные дашборды PromEx.** Нужна ли норма? Варианты: экспорт `mix prom_ex.dashboard.export` без
   правок руками; доработка только своим дашбордом; `dashboards/0` пуст при `grafana: :disabled`.
   Случай `beam.json` + cgroup показывает, что правка копии теряется при повторном экспорте.
5. **«Форма панелей».** Переносить ли норму A и её ратчет в `docs/rules/app/21-observability.md`? Если
   core-ex поставляет дашборды, ратчет логично держать в core-ex. Добавлять ли ратчет имён метрик в
   дашбордах против `plugins/0`?
6. **`infra.json` (экспортёры).** Это забота окружения, а не библиотеки? Он завязан на имена job и не
   фильтруется по экземплярам.
7. **Oban Web как норма яруса потребителя.** Отдельный эндпоинт A опирается на допущение «у приложения
   нет аутентификации». Приложению с аутентификацией, возможно, правильнее монтировать дашборд в
   основной роутер с `resolver:` / `on_mount`. Нужна ли норма с развилкой? Как быть со случайным
   `secret_key_base` при нескольких нодах? Нужна ли норма про read-only? Компонентом core-ex это быть
   не может: у core-ex нет зависимости от `oban` (`mix.exs`).
8. **Tidewave.** Нужна ли норма яруса потребителя (dev-only, место плага, `.mcp.json`, один dev-узел)
   или это дело каждого приложения? Свод core-ex про агентские инструменты молчит.
9. **Порты служебных эндпоинтов.** Выносить ли в свод общий шаблон «служебный порт: `ip:` loopback
   вне prod, на хост не публикуется, корень с тумблером и `:ignore`», общий у сервера метрик и
   дашборда Oban (`A: config/runtime.exs:145-159`, `A: test/app_a_app/listen_ip_test.exs:1-10`)?
