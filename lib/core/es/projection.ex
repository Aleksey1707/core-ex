defmodule Core.Es.Projection do
  @moduledoc """
  Builder проекции (`use`), её behaviour, прогон одной пачки `run_once/2` и генерируемое ожидание
  проекции после записи `await/3`.

      defmodule MyApp.Domain.<BC>.AccountList.Projection do
        alias MyApp.Domain.<BC>.Account

        use Core.Es.Projection,
          name: "account_list",
          events: [Account.Event.Opened, Account.Event.Closed],
          version: 1

        @impl true
        def project(%Account.Event.Opened{} = event), do: ...
        def project(%Account.Event.Closed{} = event), do: ...

        @impl true
        def clear, do: ...
      end

  Проекция строит read-модель из событий хранилища (`Core.Es.Store`) агрегатов обоих видов в
  порядке глобальной позиции. Read-модель и чекпоинт (`es_checkpoints`, `Core.Es.Migration`)
  меняются в одной транзакции (`docs/adr/0009-projections-read-event-store.md`).

  ## Колбэки

  - `project(event)` → `Result.unit()` — событие модуля из `events:` в транзакции
    пачки, без `Context`; read-модель пишется через `DAO`.
  - `clear()` → `Result.unit()` — очистить все таблицы read-модели; зовётся при
    старте с начала истории.

  Оба колбэка обязательны. Полноту `project/1` проверяет сборка проекции («Полнота `project/1`»),
  очистку таблиц `clear/0` — `Core.Es.ProjectionCase`.

  ## Полнота `project/1`

  Сборка проекции проверяет `project/1` по `events:`: на каждый модуль события макрос генерирует
  функцию-проверку (`Core.Es.Check`) — литеральный вызов
  `project(%Event.Mod{payload: %Payload{}} = event)`, у события без нагрузки `payload: nil`.
  Предупреждение компилятора указывает на строку `use`, а имя функции в нём называет нарушенное
  утверждение — `"project/1 принимает <Event>"`. Ловятся:

  - модуль `events:` без clause `project/1`;
  - опечатка в поле нагрузки, которую clause не сузила паттерном `%Payload{}`.

  ## События

  Кодек модуля события — `codec:` его семейства (`family:` у `use Core.Es.Event`), тип агрегата —
  `type:` кодека. Пачка читает события типов агрегатов из `events:` и решает по тегу, прошедшему
  цепочку `upcasts:` кодека:

  - тег модуля из `events:` — событие грузится кодеком с апкастом и уходит в `project/1`;
  - тег, известный кодеку, но не объявленный, — событие пропускается без загрузки;
  - тег, неизвестный кодеку, — ошибка загрузки `:unknown_event_type`
    (`docs/adr/0010-event-evolution-tag-upcast.md`).

  ## Персональные данные

  Событие из `events:` с полем нагрузки `subject:` несёт ПДн (ADR-0079). Проекция с таким событием
  объявляет одно из двух:

  - событие уничтожения ключа `Core.Es.Personal.Event.KeyDestroyed` в `events:` — read-модель по
    нему перестаёт держать ПДн субъекта; clause `project/1` на него проверяет сборка, как у любого
    модуля `events:`, пачка читает поток субъекта `"core.subject"`, а `await/3` получает clause
    `await(Core.Es.Personal, %Core.Es.Personal.SubjectID{}, timeout)`;
  - `personal: false` — read-модель ПДн не держит.

  Проверку read-модели после события уничтожения ключа делает `Core.Es.ProjectionCase`.

  ## Пачка

  `run_once/2` — одна транзакция `repo:` на пачку до `batch_size:` событий:

  1. `pg_try_advisory_xact_lock` по имени проекции; не взята — `:locked`;
  2. строки чекпоинта нет или её версия ниже `version:` — старт с начала истории: `clear/0`, CAS
     строки в начало со своей версией и целью пересборки, `info` — `:processed`;
  3. версия строки выше `version:` — `:outdated`, события не читаются;
  4. события после чекпоинта; их нет — `:idle`;
  5. `project/1` на каждое, CAS чекпоинта по прочитанной строке — `:processed`.

  Пачка с исходом `:processed` в той же транзакции шлёт `NOTIFY` в канал сигнала чекпоинта
  (`Core.Es.Projection.Listener`); не шлёт, если на ноде дерево стартовало с
  `notifications: false`.

  Любой отказ откатывает пачку, чекпоинт остаётся на месте:

  - `{:error, _}` колбэка и ошибка загрузки события — `{:error, Error.t()}` как есть;
  - исключение колбэка — `Logger.warning` с текстом и прикладная ошибка без текста: `ns: :es`,
    `code: :projection_raised`, detail — `%{projection, callback, exception}`, где `exception` —
    модуль исключения;
  - CAS не обновил строку — прикладная `:checkpoint_conflict`.

  ## Пересборка

  Подъём `version:` пересобирает проекцию на месте
  (`docs/adr/0011-projection-rebuild-by-version.md`): первая пачка новой версии очищает
  read-модель и возвращает чекпоинт в начало, а пачка кода с версией ниже строки получает
  `:outdated`. Понижения версии строки нет. Удалённая вручную строка чекпоинта — тоже старт с
  начала; строку удалённой проекции убирает миграция потребителя
  (`Core.Es.Migration.delete_checkpoint/1`), библиотека строки сама не удаляет.

  Цель пересборки — последняя позиция событий типов проекции, видимая пачке сброса. Пересборка
  идёт, пока чекпоинт ниже цели; пачка, дошедшая до цели, пишет `info`, а без событий в хранилище
  `info` пишет сама пачка сброса.

  Какие события видит пачка — `Core.Es.Store`, «Чтение по глобальной позиции». Пачка с работой —
  старт с начала или события — идёт в корневом span'е `Core.Otel.Es.project/3`. В приложении пачки
  гоняют читатели дерева `Core.Es.Projection.Supervisor`; прогон до `:idle` в тесте —
  `Core.Es.Projection.Test.run_until_idle/2`.

  ## Ожидание

  `await(Agg, %Agg.ID{} = aggregate_id, timeout)` → `Result.unit()` модуля проекции
  после commit записи ждёт, пока проекция обработает последнее событие потока агрегата, —
  read-after-write. Агрегат — владелец потока, которого называет `aggregate:` семейства событий
  (`use Core.Es.Event.Family`): event-sourced агрегат, state-stored сущность или `Core.Es.Personal`.

  `await(Agg, %Agg.ID{} = aggregate_id, %Core.Version{} = version, timeout)` ждёт событие этой
  версии потока, в том числе ещё не записанное: следующее событие, которое запишет реакция другого
  контекста, когда его версия известна по модели агрегата (ADR-0080).

  Функции генерирует `use` — clause на каждый агрегат, чьи события есть в `events:`: голова —
  литерал агрегата (`__es_aggregate__/0` семейства) и закрытый struct его ID
  (`__es_aggregate_id__/0` кодека), у `await/4` — и `%Core.Version{}`, результат сужен до
  `:ok | {:error, %Core.Error{}}`. Агрегат не из `events:`, ID другого агрегата и невозможная
  clause по результату — предупреждение при сборке вызывающего. Два владельца потока с общим ID в
  `events:` собираются: clauses различаются агрегатом.

  Цель `await/3` — позиция последнего события потока на момент вызова, `await/4` — позиция
  события версии `version`, даже если поток ушёл дальше:

  - поток пуст — у `await/3` `:ok`;
  - события версии нет — у `await/4` цель перечитывается на каждом сигнале и шаге, а исходы —
    прежние: пересборка — сразу `:projection_rebuilding`, событие не появилось за `timeout` —
    `:projection_timeout`;
  - чекпоинт не ниже цели — `:ok`, при любой версии строки и во время пересборки;
  - строки чекпоинта нет, её версия ниже `version:` или чекпоинт ниже цели пересборки — сразу
    прикладная `:projection_rebuilding`;
  - иначе ожидание сигнала чекпоинта с шагами страховки — удвоение от `await_min_ms:` до
    `await_max_ms:` дерева (по умолчанию 10 и 100 мс); истёк `timeout` — прикладная
    `:projection_timeout` с `timeout` в detail. Проекция в повторе чекпоинт не двигает, и
    ожидание идёт до таймаута.

  Сигнал чекпоинта приходит после commit пачки, включая старт пересборки: пачку любой ноды
  доносит `NOTIFY` её транзакции через слушателя канала (`Core.Es.Projection.Listener`), пачку своей
  ноды сигналит ещё и её читатель (`Core.Es.Projection.Reader`) — кластер Erlang не нужен.
  Ожидающий подписан на сигнал до чтения цели и по сигналу перечитывает чекпоинт тем же разбором
  исходов: ответ приходит за время пачки, а не шага. После
  ожидания при любом исходе подписка снимается, а доставленные сигналы вычерпываются — mailbox
  вызывающего, GenServer или LiveView, остаётся чистым. На время ожидания подписка связывает
  вызывающего с `Core.Es.Projection.Registry` (`Registry.register/3`): остановка дерева посреди
  ожидания завершает вызывающего без `trap_exit`, а с `trap_exit` приносит ему `{:EXIT, _, _}`.

  Шаги идут по расписанию от начала ожидания и сигналами не сдвигаются. На каждом шаге ожидающий
  перечитывает чекпоинт и будит читателя проекции на своей ноде: пачка при `wake` после записи не
  видит событие, пока открыта более старая пишущая транзакция кластера (`Core.Es.Store`, «Чтение
  по глобальной позиции»), и без пробуждения читатель простоял бы до `poll_interval_ms:` дерева.
  Уведомление, потерянное на разрыве соединения слушателя или в пулере, ожидание догоняет шагом.
  Пачку ноды с `notifications: false` ожидающий другой ноды находит шагом; нода без читателей и
  слушателей (`enabled: false`) ждёт одними шагами. Шаг позже `timeout` не наступает: на
  последнем отрезке перед таймаутом чекпоинт перечитывает только сигнал.

  Режим — опция `await:` дерева `Core.Es.Projection.Supervisor` из его отметки. При `:inline`
  (тестовое дерево) `await/3` и `await/4` прогоняют проекцию до `:idle` в вызывающем процессе с
  `batch_size` дерева и сверяют чекпоинт с целью; иной исход — `RuntimeError` с исходом и именем
  проекции. События версии у `await/4` после `:idle` нет — сразу `:projection_timeout`: записать
  его в тесте некому.

  Ошибки программиста: агрегат вне `events:` или ID другого агрегата — `FunctionClauseError`;
  вызов внутри транзакции `repo:` — `ArgumentError`; дерево проекций на ноде не стартовало —
  `RuntimeError`; проекция не из `projections:` дерева — `ArgumentError`.

  Ожидание идёт в span'е `Core.Otel.Es.await/5` внутри трейса вызывающего. Telemetry
  `[:es, :projection, :await]` (`Core.Telemetry.event/1`): измерение `duration` (native),
  метаданные `projection` — имя и `result: :ok | :timeout | :rebuilding`; `raise` её не шлёт.

  ## Opts

  - `name:` — имя проекции, непустая строка; неизменяемо: другое имя — другая проекция
  - `events:` — непустой список модулей событий (`use Core.Es.Event`) без повторов
  - `version:` — версия проекции, целое ≥ 1, по умолчанию 1
  - `personal:` — только `false`: read-модель ПДн не держит («Персональные данные»)
  - `repo:` — Ecto-репозиторий транзакции пачки; по умолчанию `Core.Config.dao/0` в рантайме
  - `codec:` — фасад вложенных значений событий; по умолчанию `Core.Config.codec/0` в рантайме

  Все опции — литералы (`docs/rules/20-agreements.md`, «Опции `use`»): ключи и значения
  проверяются при раскрытии `use`, атрибут или вызов функции в опции — `CompileError`
  «ожидается литерал».

  При раскрытии `use` `CompileError`: `name:` не непустая строка; `version:` не целое ≥ 1;
  `events:` пустой, с повтором, с модулем, который не событие или не собран (модуль события в
  проекцию не вкладывается), с семейством событий, с событием, чей `family:` не семейство
  (`use Core.Es.Event.Family`), с событием, у семейства которого `codec:` не найден, не кодек с
  `type:` или кодек другого семейства, с событием, не объявленным в `tags:` кодека, с двумя
  кодеками одного типа агрегата; событие с полем `subject:` без события уничтожения ключа и без
  `personal: false` или с обоими; `personal:` не `false` или без событий с полями `subject:`. При
  сборке модуля — нет `project/1` или `clear/0`.

  Макрос занимает в вызывающем модуле имена `@es_projection`, `@es_use_line`, `await/3` и
  функций-проверок, по одному на модуль `events:`.
  """

  alias Core.Error
  alias Core.Es
  alias Core.Es.Personal.Event.KeyDestroyed
  alias Core.Es.Projection.Batch
  alias Core.Helper
  alias Core.Result

  @label "Es.Projection"
  @required_keys ~w(name events)a
  @optional_keys ~w(version personal repo codec)a
  @expression_keys ~w()a
  @default_version 1
  @default_batch_size 100

  @typedoc "События одного типа агрегата: кодек и объявленные теги."
  @type stream :: %{codec: module(), tags: MapSet.t(String.t())}

  @typedoc "Объявление проекции — `__es_projection__/0`."
  @type t :: %{
          name: String.t(),
          version: pos_integer(),
          events: [module()],
          streams: %{optional(String.t()) => stream()},
          dao: module(),
          codec: module()
        }

  @typedoc "Исход пачки."
  @type outcome :: :processed | :idle | :locked | :outdated | {:error, Error.t()}

  @doc "Событие модуля из `events:` → read-модель."
  @callback project(event :: Es.Event.t()) :: Result.unit()

  @doc "Очистить все таблицы read-модели."
  @callback clear() :: Result.unit()

  # ===== объявление =====

  @doc "Объявить проекцию."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)
    dao = Helper.Opts.module_or_config!(opts, :repo, :dao, @label)
    codec = Helper.Opts.module_or_config!(opts, :codec, :codec, @label)
    declaration = declaration!(opts)

    quote do
      @behaviour Core.Es.Projection
      @before_compile Core.Es.Projection
      @es_use_line unquote(__CALLER__.line)
      @es_projection unquote(Macro.escape(declaration))

      @doc false
      @spec __es_projection__() :: Core.Es.Projection.t()

      def __es_projection__,
        do: Map.merge(@es_projection, %{dao: unquote(dao), codec: unquote(codec)})
    end
  end

  # ---

  defp declaration!(opts) do
    pairs = events!(Keyword.fetch!(opts, :events))
    :ok = personal!(pairs, Keyword.get(opts, :personal))

    %{
      name: name!(Keyword.fetch!(opts, :name)),
      version: version!(Keyword.get(opts, :version, @default_version)),
      events: Enum.map(pairs, &elem(&1, 0)),
      streams: streams!(pairs)
    }
  end

  defp name!(name) when is_binary(name) and name != "", do: name
  defp name!(name), do: Helper.Opts.reject!("#{@label}: name", "ожидается непустая строка, получено #{inspect(name)}")

  defp version!(version) when is_integer(version) and version >= 1, do: version

  defp version!(version),
    do: Helper.Opts.reject!("#{@label}: version", "ожидается целое ≥ 1, получено #{inspect(version)}")

  defp events!([_ | _] = events) do
    ensure_unique!(events)
    Enum.map(events, &{&1, event_codec!(&1)})
  end

  defp events!(events) do
    Helper.Opts.reject!(
      "#{@label}: events",
      "ожидается непустой список модулей событий, получено #{inspect(events)}"
    )
  end

  defp ensure_unique!(events) do
    case Enum.uniq(events -- Enum.uniq(events)) do
      [] -> :ok
      repeated -> Helper.Opts.reject!("#{@label}: events", "модули объявлены дважды: #{inspect(repeated)}")
    end
  end

  defp event_codec!(mod) when is_atom(mod) and not is_nil(mod) do
    cond do
      not compiled?(mod) ->
        Helper.Opts.reject!(
          "#{@label}: events",
          "модуль #{inspect(mod)} не найден или не собран — модуль события в проекцию не вкладывается"
        )

      Helper.Module.exports?(mod, :__es_payload__, 0) ->
        codec!(mod, family!(mod))

      family?(mod) ->
        Helper.Opts.reject!("#{@label}: events", "#{inspect(mod)} — семейство событий, объявляются модули событий")

      true ->
        Helper.Opts.reject!("#{@label}: events", "#{inspect(mod)} — не модуль события (use Core.Es.Event)")
    end
  end

  defp event_codec!(other),
    do: Helper.Opts.reject!("#{@label}: events", "ожидается модуль события, получено #{inspect(other)}")

  # Семейство события — его ссылка `family:`: по нему находятся кодек и агрегат `await/3`.
  defp family!(mod) do
    family = mod.__es_family__()

    cond do
      not compiled?(family) ->
        Helper.Opts.reject!(
          "#{@label}: events",
          "семейство #{inspect(family)} события #{inspect(mod)} не найдено — family: события"
        )

      family?(family) ->
        family

      true ->
        Helper.Opts.reject!(
          "#{@label}: events",
          "#{inspect(mod)} — событие вне семейства: family: #{inspect(family)} — " <>
            "не семейство событий (use Core.Es.Event.Family)"
        )
    end
  end

  defp codec!(mod, family) do
    codec = family.__es_codec__()

    cond do
      not compiled?(codec) ->
        Helper.Opts.reject!(
          "#{@label}: events",
          "кодек #{inspect(codec)} события #{inspect(mod)} не найден — codec: семейства #{inspect(family)}"
        )

      not Es.Event.Codec.codec?(codec) ->
        Helper.Opts.reject!(
          "#{@label}: events",
          "#{inspect(codec)} события #{inspect(mod)} — не кодек событий с type: (use Core.Es.Event.Codec), " <>
            "codec: семейства #{inspect(family)}"
        )

      codec.__codec_union__() != family ->
        Helper.Opts.reject!(
          "#{@label}: events",
          "семейство #{inspect(family)} события #{inspect(mod)} объявляет codec: #{inspect(codec)} — " <>
            "кодек семейства #{inspect(codec.__codec_union__())}"
        )

      mod not in codec.__es_mods__() ->
        Helper.Opts.reject!("#{@label}: events", "#{inspect(mod)} не объявлен в tags: #{inspect(codec)}")

      true ->
        codec
    end
  end

  defp family?(mod), do: Helper.Module.exports?(mod, :__es_codec__, 0)

  defp compiled?(mod), do: match?({:module, _}, Code.ensure_compiled(mod))

  # Событие с полем `subject:` несёт ПДн: read-модель либо чистит их по событию уничтожения ключа,
  # либо объявляет, что ПДн не держит (ADR-0079).
  defp personal!(pairs, personal) when personal in [nil, false] do
    subject_events = for {mod, codec} <- pairs, Map.has_key?(codec.__es_subjects__(), mod), do: mod
    personal!(subject_events, List.keymember?(pairs, KeyDestroyed, 0), personal)
  end

  defp personal!(_pairs, personal),
    do: Helper.Opts.reject!("#{@label}: personal", "ожидается false, получено #{inspect(personal)}")

  defp personal!([], _destroyed?, nil), do: :ok
  defp personal!([_ | _], true, nil), do: :ok
  defp personal!([_ | _], false, false), do: :ok

  defp personal!([], _destroyed?, false),
    do: Helper.Opts.reject!("#{@label}: personal", "false не нужна — у событий events: нет полей subject:")

  defp personal!(subject_events, false, nil) do
    Helper.Opts.reject!(
      "#{@label}: events",
      "#{inspect(subject_events)} несут поля subject: — объяви #{inspect(KeyDestroyed)} в events: " <>
        "(read-модель чистит ПДн субъекта) или personal: false (read-модель ПДн не держит)"
    )
  end

  defp personal!(_subject_events, true, false),
    do:
      Helper.Opts.reject!("#{@label}: personal", "false вместе с #{inspect(KeyDestroyed)} в events: — объявляется одно")

  defp streams!(pairs) do
    pairs
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.reduce(%{}, fn {codec, mods}, streams -> put_stream!(streams, codec, mods) end)
  end

  defp put_stream!(streams, codec, mods) do
    type = codec.__es_type__()

    case Map.fetch(streams, type) do
      {:ok, %{codec: other}} ->
        Helper.Opts.reject!(
          "#{@label}: events",
          "тип агрегата #{inspect(type)} у двух кодеков: #{inspect(codec)} и #{inspect(other)}"
        )

      :error ->
        Map.put(streams, type, %{codec: codec, tags: MapSet.new(mods, &codec.type/1)})
    end
  end

  # ===== генерация =====

  @doc false
  defmacro __before_compile__(env) do
    Enum.each([project: 1, clear: 0], &ensure_defined!(env, &1))

    quote do
      unquote(await_ast(env.module))
      (unquote_splicing(project_checks(env.module)))
    end
  end

  # ---

  defp ensure_defined!(env, {fun, arity}) do
    unless Module.defines?(env.module, {fun, arity}) do
      raise CompileError,
        description: "#{@label}: #{inspect(env.module)} обязан объявить #{fun}/#{arity}",
        file: env.file,
        line: env.line
    end
  end

  defp await_ast(module) do
    aggregates = aggregates(Module.get_attribute(module, :es_projection).streams)
    modules = union(for {aggregate, _id, _type} <- aggregates, do: aggregate)
    ids = union(for {_aggregate, id, _type} <- aggregates, do: quote(do: unquote(id).t()))

    quote do
      @doc """
      Дождаться, пока проекция обработает последнее событие потока агрегата `aggregate_id`, —
      не дольше `timeout` мс; первый аргумент — модуль агрегата. Исходы — `Core.Es.Projection`,
      «Ожидание».
      """
      @spec await(unquote(modules), unquote(ids), non_neg_integer()) :: Core.Result.unit()

      unquote_splicing(Enum.map(aggregates, &await_clause/1))

      @doc """
      Дождаться, пока проекция обработает событие версии `version` потока агрегата
      `aggregate_id`, в том числе ещё не записанное, — не дольше `timeout` мс; первый аргумент —
      модуль агрегата. Исходы — `Core.Es.Projection`, «Ожидание».
      """
      @spec await(unquote(modules), unquote(ids), Core.Version.t(), non_neg_integer()) ::
              Core.Result.unit()

      unquote_splicing(Enum.map(aggregates, &await_version_clause/1))
    end
  end

  # Агрегат — владелец потока `aggregate:` семейства кодека: семейство кодека и события сверено при
  # сборке объявления (`codec!/2`).
  defp aggregates(streams) do
    for {type, %{codec: codec}} <- streams,
        do: {codec.__codec_union__().__es_aggregate__(), codec.__es_aggregate_id__(), type}
  end

  defp union(types), do: Enum.reduce(types, &quote(do: unquote(&2) | unquote(&1)))

  defp await_clause({aggregate, id, type}) do
    quote generated: true do
      def await(unquote(aggregate), %unquote(id){} = aggregate_id, timeout)
          when is_integer(timeout) and timeout >= 0 do
        case Core.Es.Projection.Await.run(
               __MODULE__,
               __es_projection__(),
               unquote(type),
               aggregate_id,
               :current,
               timeout
             ) do
          :ok -> :ok
          {:error, %Core.Error{} = error} -> {:error, error}
        end
      end
    end
  end

  defp await_version_clause({aggregate, id, type}) do
    quote generated: true do
      def await(unquote(aggregate), %unquote(id){} = aggregate_id, %Core.Version{} = version, timeout)
          when is_integer(timeout) and timeout >= 0 do
        case Core.Es.Projection.Await.run(
               __MODULE__,
               __es_projection__(),
               unquote(type),
               aggregate_id,
               version,
               timeout
             ) do
          :ok -> :ok
          {:error, %Core.Error{} = error} -> {:error, error}
        end
      end
    end
  end

  defp project_checks(module) do
    line = Module.get_attribute(module, :es_use_line)

    for event <- Module.get_attribute(module, :es_projection).events do
      args = [quote(do: unquote(Es.Check.event_pattern(event)) = event)]
      Es.Check.define("project/1 принимает", event, args, quote(do: project(event)), line)
    end
  end

  # ===== пачка =====

  @doc """
  Прогнать одну пачку проекции `projection` в вызывающем процессе.

  `batch_size:` — сколько событий читает пачка, по умолчанию #{@default_batch_size}. Шаги и
  исходы — в `@moduledoc`. Вызов внутри транзакции `repo:` проекции — `ArgumentError`: пачка
  открывает свою.
  """
  @spec run_once(module(), keyword()) :: outcome()

  def run_once(projection, opts \\ []) when is_atom(projection) and is_list(opts) do
    [batch_size: batch_size] = Keyword.validate!(opts, batch_size: @default_batch_size)

    projection
    |> Batch.run(projection.__es_projection__(), batch_size)
    |> outcome()
  end

  # ---

  defp outcome({:processed, _event_count}), do: :processed
  defp outcome({:error, %Error{} = error, _failure}), do: {:error, error}
  defp outcome(outcome) when outcome in ~w(idle locked outdated)a, do: outcome
end
