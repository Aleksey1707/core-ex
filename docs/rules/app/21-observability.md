# Наблюдаемость приложения

- **Область.** `lib/my_app_app/prom_ex*`, `lib/my_app_app/metrics_server.ex`, корни дашборда
  Oban Web (`lib/my_app_app/oban_dashboard*`, `lib/my_app_web/oban_dashboard*`),
  `deploy/monitoring/**`, ключи `:sentry` и `:oban_met` в `config/*.exs`: служебные эндпоинты,
  дашборды, правила алертов, списки наблюдаемых сущностей, конфигурация службы учёта ошибок.
- **Читать перед.** Новой метрикой, дашбордом или правилом алерта; правкой списков процессов и
  кешей под наблюдением; новым служебным эндпоинтом или подключением Oban Web; подключением
  трассировки или службы учёта ошибок; адаптером внешней системы.
- **Словарь.** Плейсхолдеры и модальность — `deps/core/docs/rules/00-index.md`.

Нормы самих сигналов — предметная нейтральность `Core.Otel`, словари semconv, где ставить span,
атрибуты и запрет чувствительных данных в них — нормирует
`deps/core/docs/rules/21-observability.md`. Здесь — то, что решает приложение.

## Разделение труда

| Сигнал | Чем | Где живёт |
|---|---|---|
| Метрики | `:telemetry` + PromEx-плагины (`Core.*.PromEx`, `PromEx.Plugins.*`) | Prometheus |
| Трейсы | `opentelemetry_api` через `Core.Otel` | OTLP-коллектор |
| Логи | `Logger` в stdout | агент-сборщик, связь по `trace_id` |
| Критические ошибки | `Core.Web.CriticalError` и LoggerHandler SDK Sentry | служба учёта ошибок |

Новый показатель — это `:telemetry`-событие плюс строка в PromEx-плагине. Вводить для того же
числа вторую систему счёта MUST NOT: два несходящихся значения и два места починки.

Префикс имён метрик — `otp_app` из `use PromEx` приложения: плагины `Core.*.PromEx` называют
метрики `my_app_prom_ex_<плагин>_…` (`PromEx.metric_prefix/2`). Менять его у работающей
установки MUST NOT: имена в дашбордах и алертах завязаны на префикс. `telemetry_prefix`
(`10-architecture.md`) задаёт только имена telemetry-событий, метрики от него не зависят.

## Метрики

Плагины перечисляет `MyAppApp.PromEx.plugins/0` — единственное место, где метрика включается в
экспорт.

- Плагин, которому нужен список наблюдаемых сущностей, MUST получать его **MFA-провайдером**
  (`{MyAppApp.Application, :watch_list, []}`), а не готовым списком: список принадлежит
  рантайму и пересобирается на каждом цикле сбора, иначе процесс, поднятый позже сборки
  плагинов, в метрики не попадёт. Провайдер отдаёт `watch_list/0` приложения — конкатенацию
  списков контекстов, компонентов, готовых деревьев и элементов разделяемой инфраструктуры
  (`17-otp-concurrency.md`, «Наблюдение за процессами»). Части контекстов — читателей
  подписчиков и кеши под наблюдением — провайдер берёт из `stream_readers/0`, `kafka_readers/0` и
  `caches/0` их объявлений `<BC>.Supervision` (`17-otp-concurrency.md`, «Объявления контекста»).
- Провайдер MUST брать репозиторий через `Core.Config.repo!/1`, а не звать реализацию напрямую.
- Плагин корня, который подписан на события компонента контекста, MUST брать их имена из модуля
  telemetry компонента (`<Component>.Telemetry`), а не литералом: модуль входит в `exports`
  контекста (`10-architecture.md`, «Boundary»), и переименованное событие ломает сборку плагина, а
  не молча обнуляет метрику.

  ```elixir
  # плохо — литерал имени события компонента: переименование молча обнулит метрику
  counter("my_app.order.dispatch.sent.count", event_name: [:my_app, :order, :dispatch, :sent])

  # хорошо — имя из модуля telemetry компонента, экспортированного контекстом
  counter("my_app.order.dispatch.sent.count",
    event_name: MyApp.Domain.Orders.Order.Dispatch.Telemetry.sent()
  )
  ```
- Сбой провайдера поглощают два уровня `rescue`, поэтому метрика застывает **незаметно** для
  алерта на неё: сбой виден только `PromExCollectFailing`
  (`deps/core/docs/rules/21-observability.md`, «Рекомендованные алерты»), а провайдер, который
  молчит без сбоя, — ничем. Провайдер MUST быть закрыт тестом «публикует, а не молчит».
- Элемент выключенного компонента в список MUST NOT попадать, иначе он даёт вечный алерт о
  падении (`deps/core/docs/rules/17-otp-concurrency.md`, «Дерево процессов»); фильтрует его корень
  компонента своим тумблером, а не провайдер.
- Недоступный кеш провайдер размеров MUST пропускать: гейдж уходит в stale, а не в ноль.
- Список, который уже собирает дерево процессов, вторым списком в PromEx MUST NOT: плагин и
  дерево разошлись бы молча (`17-otp-concurrency.md`). Для проекций это та же
  `MyAppApp.Application.projection_opts/0`, что поднимает дерево: у `Core.Es.PromEx` она идёт
  ключом `projections:`; `processes:` — тот же `MyAppApp.Application.processes/0`, что поднимает
  процессы агрегата, и задаётся, только если они есть.
- Уровень детализации и `poll_rate` — общие для всех плагинов приложения; отклонение
  фиксируется в `DEBT.md`. Провайдер, который ходит в БД за медленно меняющимся состоянием,
  MAY опрашиваться реже — это и есть такое отклонение.

Проверяется: ратчет состава плагинов и провайдеров (`19-testing.md`, «Ратчеты»).

## Служебный эндпоинт

Служебный эндпоинт (`CONTEXT.md`, «Служебный эндпоинт») — сервер метрик, дашборд Oban Web на
отдельном эндпоинте — устроен по одному шаблону; разный у них только плаг.

- Порт MUST быть свой: отдавать служебное с `MyAppWeb.Endpoint` MUST NOT. Клиентский порт
  публикуется наружу, а на служебный не действуют `force_ssl`, аутентификация и прочие пайплайны
  клиентов.
- Адрес задаёт ключ `ip:` конфигурации корня: `{0, 0, 0, 0}` — только в prod, где к порту ходят
  Prometheus и обратный прокси из соседнего контейнера; вне prod — `{127, 0, 0, 1}`. Литерал
  адреса в `lib/` MUST NOT: `0.0.0.0` на машине разработчика открывает служебный порт локальной
  сети, а дашборд Oban на нём — без логина.
- Публиковать порт на хост (`ports:` в compose) MUST NOT: к нему ходят только Prometheus и
  прокси по сети контейнеров. Локальный стенд MAY пробросить его на `127.0.0.1` хоста.
- Корень служебного эндпоинта владеет тумблером, конфигурацией и `watch_list/0`, как корень
  компонента (`17-otp-concurrency.md`, «Компонент», «Конфигурация корня», «Тумблер компонента»);
  место в дереве — `17-otp-concurrency.md`, «Дерево процессов».
- В `config/test.exs` служебный эндпоинт MUST быть выключен: порт на машине один, и параллельный
  прогон тестов или запущенный рядом dev-узел роняют старт на `eaddrinuse`.

```elixir
# плохо — адрес литералом в корне: dev-узел открывает служебный порт локальной сети
children = [
  {Bandit, plug: {Core.Web.MetricsPlug, prom_ex_module: MyAppApp.PromEx}, ip: {0, 0, 0, 0}}
]

# хорошо — config/runtime.exs: адрес и тумблер задаёт окружение; test.exs тумблер выключает
if config_env() != :test do
  listen_ip = if config_env() == :prod, do: {0, 0, 0, 0}, else: {127, 0, 0, 1}

  config :my_app, MyAppApp.MetricsServer,
    enabled: System.get_env("METRICS_SERVER_ENABLED", "true") == "true",
    ip: listen_ip,
    port: String.to_integer(System.get_env("METRICS_SERVER_PORT", "9568"))
end
```

```yaml
# плохо — служебный порт опубликован на все адреса хоста
ports: ["9568:9568"]

# хорошо — локальный стенд: только loopback хоста; в prod-compose ports: нет вовсе
ports: ["127.0.0.1:9568:9568"]
```

## Сервер метрик

Сервер метрик `MyAppApp.MetricsServer` — служебный эндпоинт («Служебный эндпоинт»):

- плаг сервера — `Core.Web.MetricsPlug`: на чужом пути он отвечает 404, тогда как штатный плаг
  PromEx пропустил бы `conn` дальше и адаптер отдал бы 500;
- в `config/test.exs` вместе с сервером отключён PromEx.

## Oban Web

Дашборд Oban Web меняет задачи — отменяет, удаляет, перезапускает, — поэтому место дашборда
выбирает аутентификация приложения:

| Аутентификация оператора в браузере | Где дашборд | Доступ |
|---|---|---|
| нет | служебный эндпоинт: корень `MyAppApp.ObanDashboard`, эндпоинт `MyAppApp.ObanDashboard.Endpoint` со своим роутером | пускают сеть и обратный прокси с логином; внутри — резолвер по умолчанию |
| есть: сессия, пользователь в `conn.assigns` | маршрут `oban_dashboard` в `MyAppWeb.Router` за пайплайном аутентификации; корень `MyAppWeb.ObanDashboard` держит только сборщик метрик | `resolver:` — свой `Oban.Web.Resolver`, по умолчанию только чтение |

- Дашборд без аутентификации в `MyAppWeb.Router` MUST NOT: клиентский порт публикуется наружу, и
  задачи правит любой, кто до него дошёл.
- Без аутентификации порт дашборда MUST закрывать обратный прокси с логином. Прокси MUST
  пропускать upgrade до websocket: без него страница грузится, но не обновляется. Страница,
  ассеты и сокет LiveView SHOULD лежать под одним префиксом (`socket_path:` у `oban_dashboard`),
  чтобы прокси хватало одного `location`.
- Сокет LiveView служебного эндпоинта сверяет `Origin` с `url: [host:]` эндпоинта — умолчание
  `check_origin`. `check_origin: false` и `check_origin: :conn` MUST NOT: от DNS rebinding они не
  защищают — у перерезолвленного на loopback домена `Origin` и `Host` совпадают.
- С аутентификацией резолвер MUST по умолчанию давать `:read_only`, `:all` — только роли с правом
  менять задачи, без пользователя — `{:forbidden, path}`: резолвер по умолчанию
  (`Oban.Web.Resolver`) даёт `:all` каждому, кто прошёл маршрут. Хук LiveView приложения MAY
  подключаться опцией `on_mount:` — такие хуки выполняются до проверки резолвера.

```elixir
# плохо — дашборд в клиентском роутере без проверки доступа: задачи правит любой
scope "/" do
  pipe_through :browser
  oban_dashboard "/oban"
end

# плохо — сокет служебного эндпоинта принимает страницу с любого Origin
socket "/oban/live", Phoenix.LiveView.Socket, check_origin: false

# хорошо — с аутентификацией: маршрут за ней, права — резолвером
scope "/" do
  pipe_through [:browser, :require_operator]
  oban_dashboard "/oban", resolver: MyAppWeb.ObanDashboard.Resolver
end

defmodule MyAppWeb.ObanDashboard.Resolver do
  @behaviour Oban.Web.Resolver

  @impl true
  def resolve_user(conn), do: conn.assigns[:current_user]

  @impl true
  def resolve_access(user) do
    case MyAppWeb.ObanDashboard.enabled?() do
      false -> {:forbidden, "/"}
      true -> access(user)
    end
  end

  defp access(nil), do: {:forbidden, "/login"}
  defp access(%{role: :admin}), do: :all
  defp access(%{}), do: :read_only
end
```

```nginx
# хорошо — без аутентификации: логин на прокси, upgrade до websocket
location /oban {
    auth_basic           "Oban";
    auth_basic_user_file /etc/nginx/oban.htpasswd;
    proxy_pass           http://app:4001;
    proxy_http_version   1.1;
    proxy_set_header     Upgrade $http_upgrade;
    proxy_set_header     Connection "upgrade";
    proxy_set_header     Host $host;
}
```

### Сборщик метрик `Oban.Met`

Дашборду нужен сборщик метрик `Oban.Met`. По умолчанию он стартует сам вместе с каждым
экземпляром Oban и опрашивает `oban_jobs`, даже когда дашборд выключен.

- Автостарт MUST быть выключен: `config :oban_met, auto_start: false` в `config/config.exs`.
- `Oban.Met` MUST стоять ребёнком корня дашборда, а не плагином в `plugins:` Oban: тумблер
  дашборда выключает только детей своего корня.
- Как и автостарт, сборщик стартует только у экземпляра с `testing: :disabled`.

```elixir
# плохо — плагин Oban: выключенный дашборд не останавливает опрос oban_jobs
config :my_app, Oban, plugins: [Oban.Met]

# хорошо — config/config.exs
config :oban_met, auto_start: false

# хорошо — init/1 корня дашборда
children = met(Oban.config(Oban)) ++ [{MyAppApp.ObanDashboard.Endpoint, endpoint_opts}]

defp met(%Oban.Config{testing: :disabled} = conf), do: [{Oban.Met, conf: conf}]
defp met(%Oban.Config{}), do: []
```

### Тумблер дашборда

Выключенный корень дашборда не поднимает ни сборщик, ни эндпоинт. Цена выключения — очереди и
задачи видны и правятся только через `iex`.

- Корень служебного эндпоинта дашборда выключается, как любой служебный эндпоинт («Служебный
  эндпоинт»).
- Корень `MyAppWeb.ObanDashboard` ветки основного роутера служебным эндпоинтом не является, но
  тумблер и `:ignore` держит так же — по `17-otp-concurrency.md`, «Компонент»; в `config/test.exs`
  он выключен. Маршрут при выключенном корне MUST отвечать отказом, а не открывать дашборд без
  сборщика: резолвер отдаёт `{:forbidden, path}` по `enabled?/0` корня (пример выше). Поэтому
  корень этой ветки лежит в `MyAppWeb`, а не в `MyAppApp`: ссылка web на корень приложения
  запрещена (`10-architecture.md`, «Boundary»).

### `secret_key_base`

У служебного эндпоинта дашборда `secret_key_base` MUST читаться из окружения в
`config/runtime.exs` и быть одинаковым на всех нодах (`10-architecture.md`, «Файлы `config/`»).
Случайный ключ на старте — MUST NOT: им подписаны сессия и токен сокета LiveView, и за
балансировщиком без sticky-сессий страница, выданная одной нодой, не подключится к сокету другой;
каждый рестарт ноды обрывает открытые страницы.

```elixir
# плохо — ключ рождается на старте: у каждой ноды свой
secret_key_base: :crypto.strong_rand_bytes(64)

# хорошо — config/runtime.exs: один ключ окружения на все ноды
config :my_app, MyAppApp.ObanDashboard,
  secret_key_base: System.fetch_env!("OBAN_DASHBOARD_SECRET_KEY_BASE")
```

## Дашборды и алерты

Дашборды провижнятся **файлами** из репозитория; аплоада по API нет.

- Дашборд правится файлом. Правка через UI теряется при пересоздании стека — экспортировать её
  в json и коммитить MUST.
- Новая метрика, ради которой заводится панель, MUST приходить вместе с правкой файла дашборда.
- Алерт MUST указывать в `annotations` **действие оператора** отдельным ключом, а не в хвосте
  описания. Алерт без runbook'а — шум: разбирать его в три часа ночи будет тот, кто не писал
  правило.
- Новый долгоживущий процесс, падение которого меняет поведение системы, MUST попадать в
  `watch_list/0` своего компонента вместе с алертом на него (`17-otp-concurrency.md`).
- Алерт на подсистему, которой в приложении ещё нет, MAY оставаться в правилах: завести его
  заново вместе с подсистемой дороже, чем держать не срабатывающим.

Пороги выбирает приложение, условия PromQL для подсистем библиотеки берутся из её свода
(`deps/core/docs/rules/21-observability.md`, «Рекомендованные алерты»;
`deps/core/docs/rules/22-projections.md`, «Эксплуатация»).

### Алерты event sourcing

Приложение с проекциями SHOULD заводить четыре алерта на метриках `Core.Es.PromEx`; условия и
смысл — таблица в `deps/core/docs/rules/22-projections.md`, пороги и `for:` выбираются по объёму
истории.

| Алерт | Что делает оператор |
|---|---|
| `EsProjectionRetrying` | найти `event_id` в `warning` читателя, починить `project/1`, выкатить: пропуска события нет |
| `EsProjectionLagging` | оборвать долгую пишущую транзакцию либо разобрать медленный `project/1` по длительности пачки |
| `EsProjectionRebuildLong` | сверить ход по убыванию отставания; стоит на месте — искать `EsProjectionRetrying` и падение читателя |
| `EsProjectionOutdated` | дотянуть выкладку до единой `version:` на всех нодах либо вернуть понижённую |

Условие пересборки у `EsProjectionLagging`, агрегация по нодам и сигналы, на которые алерт не
заводится, — там же, в «Эксплуатация».

Приложение с ПДн в событиях (поля `subject:`) SHOULD заводить ещё два алерта — на хранилище
ключей; условия PromQL и исходы без алерта — `deps/core/docs/rules/21-observability.md`,
«Рекомендованные алерты».

| Алерт | Что делает оператор |
|---|---|
| `EsPersonalUnreadable` | не уничтожать ключи и не править события: значения не потеряны, пока целы ключи. Сверить KEK окружения с версиями ключей в хранилище; после восстановления из копии — вернуть `es_subject_keys` той же точки, что `es_events` (`23-personal-data.md`, «Восстановление копии»); у своей реализации — проверить, ту ли копию хранилища она читает |
| `EsKeyStoreErrors` | по `op` и коду ошибки в `warning` читателя проекции или ответе usecase: `:kek_unknown` — вернуть в `keks` версию KEK, которой обёрнуты ключи; `:key_unresolved` — разобрать конкурентную запись ключей субъекта; `:unavailable` или отказ KMS своей реализации — восстановить доступ: пачки проекций повторятся сами |

## Трассировка

Транспорт библиотеки инструментирован (`Core.Otel`, перенос контекста заголовками очереди), но
SDK и экспортёр подключает приложение. Пока они не подключены, вызовы фасада — no-op.

- Ветки «если трассировка включена» в коде приложения MUST NOT: их роль исполняет no-op tracer.
- Код приложения, зовущий фасад напрямую, MUST передавать `scope: <свой модуль>` — иначе его
  span'ы в бэкенде выглядят как span'ы библиотеки.
- Неподключённый SDK — осознанное состояние, а не забытая задача: оно MUST быть записано в
  `DEBT.md` вместе с ценой.

## Внешние вызовы

Адаптер внешней системы (платёжный шлюз, касса, служба доставки, SMS) MUST звать систему через
`Core.External.call/4`: span, telemetry и метрики вызова ставит обёртка, исходы и их статусы —
`deps/core/docs/rules/21-observability.md`, «Где ставить span».

- `system` и `operation` — атомы закрытого множества адаптера (`:payment_gateway`, `:charge`): они
  уходят метками в Prometheus, и значение из запроса (идентификатор, сумма, телефон) в них MUST NOT.
- Классификатор `outcome:` MUST жить в адаптере рядом с разбором ответа: смысл ответов системы
  знает только он.
- Повтор MUST оборачивать `Core.External.call/4`, а не идти внутри `fun`: каждая попытка — свой
  исход и своя длительность.
- Свой span или своя метрика длительности того же вызова — MUST NOT: второй счёт того же числа.
- Приложение с внешними вызовами MUST включать `Core.External.PromEx` в
  `MyAppApp.PromEx.plugins/0` и SHOULD заводить алерты ниже с порогами по системе.

```elixir
# плохо — span и метрика своим кодом, исход неотличим от исключения
Core.Otel.span("charge", fn -> Gateway.charge(payment) end)

# хорошо
Core.External.call(:payment_gateway, :charge, fn -> Gateway.charge(payment) end,
  outcome: &Gateway.outcome/1
)
```

| Алерт | Что делает оператор |
|---|---|
| `ExternalCallFailing` | по метке `outcome`: `timeout` / `down` — проверить статус системы и сеть до неё; `rejected` — разобрать ответы системы в логе адаптера (ключ доступа, формат запроса); `exception` — найти исключение адаптера в логе, починить и выкатить |
| `ExternalCallSlow` | сверить задержку с обещанной системой по `operation`; растёт у всех операций системы — обращаться к её владельцу |

## Служба учёта ошибок

Службу учёта ошибок (Sentry) подключает приложение, которому она нужна: `{:sentry, "~> 14.0"}` в
своих зависимостях. Что пишет отчёт о критической ошибке и когда его звать —
`deps/core/docs/rules/21-observability.md`, «Отчёт о критической ошибке»; две точки ответа 500 —
`15-web-api.md`, «FallbackController». Здесь — конфигурация SDK: кроме критической ошибки API в
службу уходят только падение процесса и задача Oban, исчерпавшая попытки. HTTP-клиент SDK по
умолчанию — `:finch`: без него `:sentry` не стартует (у приложения он есть транзитивно от
`prom_ex`).

### Ключи окружения

| Ключ | Что задаёт | Не задан |
|---|---|---|
| `SENTRY_DSN` | адрес проекта в службе | отправка выключена, старт не падает |
| `SENTRY_ENVIRONMENT` | окружение события | имя окружения сборки (`config_env/0`) |
| `SENTRY_RELEASE` | версия релиза события | версия приложения из `mix.exs` |

- Пустой ключ MUST читаться как незаданный: SDK разбирает пустой `SENTRY_DSN` как DSN и роняет
  старт, пустые окружение и релиз ушли бы в событие `""`, а стенд без службы задаёт ключи пустыми.
- Умолчания `SENTRY_ENVIRONMENT` и `SENTRY_RELEASE` задаёт приложение: у SDK окружение по
  умолчанию — `"production"`, а релиза нет. Значение из `config/config.exs` SDK ключом окружения
  не перекрывает — перекрывает `config/runtime.exs`.
- В `config/test.exs` — тестовый режим SDK (`test_mode: true`, `19-testing.md`, «Внешние
  зависимости»).

```elixir
# плохо — пустой SENTRY_DSN роняет старт; окружение стенда уходит "production"
config :sentry, dsn: System.get_env("SENTRY_DSN")

# хорошо — config/config.exs: версия приложения фиксируется при сборке
config :sentry, release: Mix.Project.config()[:version]

# хорошо — config/runtime.exs
env = fn key -> with "" <- System.get_env(key), do: nil end

config :sentry,
  dsn: env.("SENTRY_DSN"),
  environment_name: env.("SENTRY_ENVIRONMENT") || to_string(config_env())

if release = env.("SENTRY_RELEASE"), do: config(:sentry, release: release)
```

### Контекст запроса

- `plug Sentry.PlugContext, body_scrubber: nil` в эндпоинте — MUST: тело запроса в службу не
  уходит вовсе, персональные данные не покидают систему. Метод, путь и query-параметры событие
  несёт — по ним запрос воспроизводится.
- Свой список заголовков к скраберу по умолчанию (`header_scrubber:` поверх
  `Sentry.PlugContext.default_header_scrubber/1`) — MAY: заголовок с секретом, которого нет в
  списке SDK (`authorization`, `authentication`, `cookie`), иначе уходит в событие открытым.
- `Sentry.PlugCapture` — MUST NOT: падение запроса записывает точка ответа 500 `ErrorJSON`
  (`15-web-api.md`), и `PlugCapture` дал бы вторую запись того же падения.
- Контекст пользователя события — только id пользователя:
  `Sentry.Context.set_user_context(%{id: …})` в плаге аутентификации. Логин, телефон, почта и
  роли — MUST NOT.
- Значения Prim с `sensitive: true` в доп. данных события скрыты их `Inspect`, как в логах
  (`deps/core/docs/rules/12-errors.md`, «Чувствительные данные»).

```elixir
# плохо — тело запроса и логин уходят в службу; падение запроса пишется дважды
use Sentry.PlugCapture
plug Sentry.PlugContext
Sentry.Context.set_user_context(%{id: user_id, username: login})

# хорошо
plug Sentry.PlugContext, body_scrubber: nil
Sentry.Context.set_user_context(%{id: InCodec.dump(user_id)})
```

### Падения процессов

Падение процесса пишет в службу LoggerHandler SDK: его подключает ключ `logs:` конфигурации.

- `capture_log_messages: false` — MUST: `Logger.error` в службу не уходит, падение процесса
  уходит и без этой опции.
- `capture_excluded_domains: [:cowboy, :bandit]` — MUST: падение обработки HTTP-запроса
  записывает точка ответа 500, лог веб-сервера дал бы вторую запись. Умолчание SDK — только
  `[:cowboy]`.
- `level:` у `logs:` — MUST NOT: он включает отправку structured logs в службу, а логи живут в
  агенте-сборщике («Разделение труда»).

```elixir
# плохо — каждый Logger.error становится записью; падение запроса под Bandit — вторая запись
config :sentry, logs: [level: :info, capture_log_messages: true]

# хорошо
config :sentry, logs: [capture_log_messages: false, capture_excluded_domains: [:cowboy, :bandit]]
```

### Oban

Задача Oban MUST уходить в службу, только исчерпав попытки: неудачная попытка, за которой
следует повтор, — штатная, и запись на каждую плодит дубли. Колбэк — функция, поэтому живёт в
`config/runtime.exs`: в `config/config.exs` релиз её не сериализует.

```elixir
# плохо — запись на каждую неудачную попытку
config :sentry, integrations: [oban: [capture_errors: true]]

# хорошо — config/runtime.exs
config :sentry,
  integrations: [
    oban: [
      capture_errors: true,
      should_report_error_callback: fn _worker, job -> job.attempt >= job.max_attempts end
    ]
  ]
```

### Трейсинг

- Трейсинг Sentry — MUST NOT: ни `traces_sample_rate` / `traces_sampler`, ни
  `Sentry.OpenTelemetry.SpanProcessor` у `:opentelemetry`. Трассы уходят через `Core.Otel` в
  OTLP-коллектор («Трассировка»), второй экспорт вытеснил бы его сэмплер.
- `trace_id` событие берёт из текущего OTel-спана, только если при сборке `:sentry` у приложения
  есть четыре OTel-приложения (`deps/core/docs/rules/21-observability.md`, «Отчёт о критической
  ошибке»). Приложение с подключённым SDK трассировки MUST держать в зависимостях все четыре;
  добавленные позже требуют пересборки `:sentry` (`mix deps.compile sentry --force`). Без SDK
  трассировки связь записи с трейсом — по времени и логам.
- Source context (`enable_source_code_context:`) — MAY, на усмотрение приложения.

```elixir
# плохо — второй экспорт трасс в обход Core.Otel; без semconv trace_id в событие не попадёт
config :sentry, traces_sample_rate: 0.1
config :opentelemetry, span_processor: {Sentry.OpenTelemetry.SpanProcessor, []}

# хорошо — mix.exs приложения с SDK трассировки: trace_id события из текущего спана
{:opentelemetry, "~> 1.5"},
{:opentelemetry_exporter, "~> 1.0"},
{:opentelemetry_semantic_conventions, "~> 1.27"},
{:sentry, "~> 14.0"}
```

## Видимость потерь

Прогон, который пропускает строки или объекты, MUST делать это видимым:

- счётчик пропусков уходит в метрику и в итог прогона — тихая потеря данных выглядит как
  успешный прогон (`12-errors.md`);
- ненулевая потеря на длинной операции (пересборка проекции, импорт) уходит в лог на
  `warning` с разбивкой по источнику;
- прогресс длинной операции пишется на `info` раз в N пачек, а не на каждую: per-batch лог на
  `info` заливает поток (`deps/core/docs/rules/20-agreements.md`).

Разбивку по причинам MAY держать только итог прогона и лог: тег причины в Prometheus стоит
отдельного события и панели ради числа, которое читают при разборе, а не по алерту.

## Связанные правила

- Конфигурация библиотеки и `telemetry_prefix` — `10-architecture.md`
- Ошибки прогонов и их цепочки — `12-errors.md`
- Цепочка очереди и разбор `:failed` — `14-events-outbox.md`
- Процессы под наблюдением — `17-otp-concurrency.md`
- Корень и тумблер служебного эндпоинта — `17-otp-concurrency.md`
- Границы web и корня приложения — `10-architecture.md`
- Метрики кеша — `16-caching.md`
- Уровни и формат логов — `20-agreements.md`
- Точки ответа 500 — `15-web-api.md`
- Тест записи в службу — `19-testing.md`
- Отчёт о критической ошибке — `deps/core/docs/rules/21-observability.md`
