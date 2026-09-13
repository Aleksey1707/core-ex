# Готовые ES-библиотеки на Elixir и их совместимость с принципами core

Type: research
Status: resolved
Map: [Event-sourced агрегат в :core](../map.md)

## Question

Какие готовые библиотеки event sourcing на Elixir с хранилищем PostgreSQL можно положить под
event-sourced агрегат `:core` и что каждая требует от потребителя:

- кандидаты: Commanded + EventStore, EventStore без Commanded, прочие живые библиотеки с hex.pm;
  сопровождение (последний релиз, активность), лицензия;
- можно ли писать события в той же транзакции, что и записи через Ecto-репозиторий потребителя
  (outbox, read-модели);
- обязательны ли процессы агрегата, router / dispatch, `Commanded.Application`; можно ли пользоваться
  агрегатом и хранилищем из обычной функции usecase;
- что библиотека требует на компиляции и в конфигурации (`use EventStore, otp_app:`, схема БД,
  mix-задачи инициализации); какие OTP-процессы поднимает и кто их супервизирует;
- точки расширения для адаптера: сериализатор, имя типа события (своё wire-имя вместо имени модуля),
  метаданные (автор, момент, correlation / causation), форма ошибки конфликта версии, telemetry;
- контракт агрегата, подписки с чекпоинтом, снапшоты, апкастинг — только то, чего нет в отчётах
  research 01–04.

Критерии `:core` — `map.md` (Notes) и `CLAUDE.md`: библиотека не знает потребителя и не требует его
конфигурации на компиляции, клиенты внешних систем — optional-зависимости.

## Answer

- Живые библиотеки на PostgreSQL: `eventstore` 1.4.8 (2025-03), `commanded` 1.4.11 (2026-07) с адаптером 1.4.2
  (2024-10, без коммитов), `maestro` 1.0.0, `ariadne_flow` 0.10.1 (DCB), а также `spector` и `ash_events`, которые
  к агрегату не относятся. Остальные либо мертвы, либо работают не на PostgreSQL.
- EventStore пишет в транзакции Ecto потребителя только через `conn:` из `Process.get({Ecto.Adapters.SQL, pool})`.
  Store при этом должен быть запущен: свой пул на 10 соединений, advisory-соединение, notifications. Ошибка
  конфликта переводит транзакцию usecase в aborted, строка `$all` заблокирована до commit.
- EventStore читает конфигурацию в рантайме, на компиляции `use EventStore` нужен только литерал `otp_app`.
  Сериализатор (`serialize/deserialize(type:)`) и `event_type` подменяются. Метаданные: `metadata`,
  causation/correlation, `created_at` из приложения. Telemetry нет (#163 открыт с 2019).
- EventStore сам назначает `stream_version` и хранит события в общих таблицах схемы. Это расходится с «версию
  поднимает домен» и с таблицей на агрегат. Миграции — свои mix-задачи и `schema_migrations`.
- Commanded выполняет команду только так: `Commanded.Application` → router → процесс агрегата. Append идёт вне
  транзакции вызывающего. Это прямо конфликтует с решением карты о пути команды и с Out of scope.
- `use Commanded.Application` снимает app env при компиляции, runtime-конфиг — только через `init/1`.
  TypeProvider (wire-имя) глобален на VM. Telemetry есть; OTel — сторонний пакет с обязательным SDK.
- Без процессов из Commanded пригодны behaviour `execute/apply`, протокол `Upcaster`, `Aggregate.Multi` — поверх
  EventStore со всеми ограничениями варианта «EventStore + адаптеры».
- Maestro: GenServer на агрегат, глобальный `config :maestro, repo:`, в `event_log` нет колонки метаданных,
  telemetry нет.
- Ariadne Flow присоединяется к транзакции того же repo, процессов не требует, тип и encoder задаются через
  `@derive`, telemetry есть. Но модель DCB — без версии агрегата; append сериализуется advisory lock на context;
  один релиз на hex, PR не принимаются.
- Совместимость с Elixir 1.20 не подтверждена ни у одного кандидата: CI доходит до 1.17 (EventStore), 1.19
  (Commanded), 1.18 (Maestro).

[Отчёт](../research/05-es-libraries.md)
