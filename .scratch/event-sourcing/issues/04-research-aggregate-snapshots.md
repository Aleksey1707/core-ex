# Готовые решения: контракт агрегата и снапшоты

Type: research
Status: resolved
Map: [Event-sourced агрегат в :core](../map.md)

## Question

Как устроены агрегат и снапшоты в Commanded, Marten, Emmett и Message DB:

- как агрегат объявляет обработку команды и применение события (Commanded `execute/2` + `apply/2`,
  decider в Emmett — `decide` / `evolve` / `initialState`, Marten — live aggregation / `Apply`,
  Message DB — projection сущности): чистота функций, начальное состояние пустого потока, кто
  увеличивает версию;
- как команда получает текущее состояние: полная свёртка, кэш, снапшот;
- снапшоты: где хранятся, когда создаются (каждые N событий, по времени, асинхронно), формат и версия
  схемы снапшота, инвалидация при смене формы агрегата, поведение при нечитаемом снапшоте;
- как тестируют агрегат (given / when / then).

Нужно для тикетов «Контракт event-sourced агрегата» и «Снапшоты: хранение, политика, инвалидация».
Отправная точка `:core` — `map.md`, Notes.

## Answer

- **Контракт.** Commanded — `execute/2` + `apply/2` у struct (`apply` MUST NOT fail); Emmett — decider
  `decide` / `evolve` / `initialState()`; Marten — конвенции `Create` / `Apply` / `ShouldDelete`, чистота не
  требуется (`IQuerySession`); Eventide — handler плюс отдельная мутирующая проекция, сущность без I/O.
- **Версию** ни в одном решении не поднимает домен: Commanded — процесс агрегата
  (`expected_version + length(events)`), Emmett и Marten — event store (Marten заполняет член `Version`),
  Message DB — `write_message` с проверкой `expected_version`.
- **Состояние для команды.** Emmett и Marten Live — полная свёртка на каждый вызов; Commanded — GenServer в
  памяти, снапшот только для холодного старта; Eventide — кэш процесса → снапшот → хвост; Marten Inline /
  Async — документ (плюс хвост у Async), с 9.26 opt-in кэш-baseline с обязательным дочитыванием.
- **Хранение снапшота.** Commanded — таблица `snapshots` с upsert, один на агрегат; Eventide — append-only
  поток `{entity}:snapshot-{id}`, читается последнее сообщение; Marten — таблица документа с `mt_version`;
  у Emmett снапшотов нет.
- **Политика.** Commanded — каждые N событий, после ответа вне транзакции, сбой только в лог; Marten Inline —
  в транзакции append, Async — daemon; Eventide — при чтении, когда спроецировано ≥ N событий.
- **Инвалидация при смене формы.** Commanded — ручной bump `snapshot_version` в metadata → полная свёртка;
  Marten — rebuild или blue/green по `ProjectionVersion`; у Eventide не описана; Chassaing — новая коллекция
  на версию кода (хеш `evolve`).
- **Нечитаемый снапшот** нигде не документирован: Commanded сворачивает с нуля при `outdated_snapshot` и
  ошибке БД, но падает на ошибке декодирования; Eventide пробрасывает исключение (оба — вывод из кода).
- **Тесты.** Emmett — `DeciderSpecification` given-события / when / then без БД; Commanded — через store и
  dispatch (чистый `AggregateCase` лежит только в репозитории); Marten — интеграционные; Eventide — фикстуры
  с подставленными сущностью и версией.

[Отчёт](../research/04-aggregate-snapshots.md)
