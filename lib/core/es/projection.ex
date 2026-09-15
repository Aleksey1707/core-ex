defmodule Core.Es.Projection do
  @moduledoc """
  Builder проекции (`use`), её behaviour, прогон одной пачки `run_once/2` и ожидание проекции
  после записи `await/4`.

      defmodule MyApp.Domain.<BC>.<Actor>.AccountList.Projection do
        alias MyApp.Domain.<BC>.Common.Account

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

  - `project(event)` → `:ok | {:error, Error.t()}` — событие модуля из `events:` в транзакции
    пачки, без `Context`; read-модель пишется через `DAO`.
  - `clear()` → `:ok | {:error, Error.t()}` — очистить все таблицы read-модели; зовётся при
    старте с начала истории.

  Оба колбэка обязательны. Клаузу `project/1` каждого модуля `events:` и очистку таблиц `clear/0`
  проверяет `Core.Es.ProjectionCase`.

  ## События

  Кодек модуля события `<Aggregate>.Event.<Name>` — `<Aggregate>.Event.Codec`, тип агрегата —
  его `type:`. Пачка читает события типов агрегатов из `events:` и решает по тегу, прошедшему
  цепочку `upcasts:` кодека:

  - тег модуля из `events:` — событие грузится фасадом с апкастом и уходит в `project/1`;
  - тег, известный кодеку, но не объявленный, — событие пропускается без загрузки;
  - тег, неизвестный кодеку, — ошибка загрузки `:unknown_event_type`
    (`docs/adr/0010-event-evolution-tag-upcast.md`).

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

  `await/4` после commit записи ждёт, пока проекция обработает последнее событие потока агрегата,
  — read-after-write. Агрегат — модуль, в котором лежит кодек событий `<Aggregate>.Event.Codec`:
  по раскладке `11-domain.md` это сам агрегат любого вида. Цель — позиция последнего события
  потока на момент вызова:

  - поток пуст — `:ok`;
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
  (тестовое дерево) `await/4` прогоняет проекцию до `:idle` в вызывающем процессе с `batch_size`
  дерева и сверяет чекпоинт с целью; иной исход — `RuntimeError` с исходом и именем проекции.

  Ошибки программиста: тип агрегата вне `events:` — `FunctionClauseError`; вызов внутри транзакции
  `repo:` — `ArgumentError`; дерево проекций на ноде не стартовало — `RuntimeError`; проекция не из
  `projections:` дерева — `ArgumentError`.

  Ожидание идёт в span'е `Core.Otel.Es.await/4` внутри трейса вызывающего. Telemetry
  `[:es, :projection, :await]` (`Core.Telemetry.event/1`): измерение `duration` (native),
  метаданные `projection` — имя и `result: :ok | :timeout | :rebuilding`; `raise` её не шлёт.

  ## Opts

  - `name:` — имя проекции, непустая строка; неизменяемо: другое имя — другая проекция
  - `events:` — непустой список модулей событий (`use Core.Es.Event`) без повторов
  - `version:` — версия проекции, целое ≥ 1, по умолчанию 1
  - `repo:` — Ecto-репозиторий транзакции пачки; по умолчанию `Core.Config.dao/0` в рантайме
  - `codec:` — фасад загрузки событий; по умолчанию `Core.Config.codec/0` в рантайме

  На компиляции `CompileError`: нет `project/1` или `clear/0`; `name:` не непустая строка;
  `version:` не целое ≥ 1; `events:` пустой, с повтором, с модулем, который не событие, с
  семейством `<Aggregate>.Event`, с событием без кодека `<Aggregate>.Event.Codec`, с кодеком без
  `type:` или не объявившим событие в `tags:`, с двумя кодеками одного типа агрегата.

  Макрос занимает в вызывающем модуле имя `@es_projection`.
  """

  alias Core.Error
  alias Core.Es
  alias Core.Es.Projection.Await
  alias Core.Es.Projection.Batch
  alias Core.Helper

  @label "Es.Projection"
  @required_keys ~w(name events)a
  @optional_keys ~w(version repo codec)a
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
  @callback project(event :: Es.Event.t()) :: :ok | {:error, Error.t()}

  @doc "Очистить все таблицы read-модели."
  @callback clear() :: :ok | {:error, Error.t()}

  # ===== объявление =====

  @doc "Объявить проекцию."
  defmacro __using__(opts) do
    lit = Macro.expand_literals(opts, __CALLER__)
    Helper.Opts.validate!(lit, @required_keys, @optional_keys, @label)
    dao = Helper.Opts.module_or_config!(lit, :repo, :dao, @label)
    codec = Helper.Opts.module_or_config!(lit, :codec, :codec, @label)

    # `name:`, `events:` и `version:` уходят в тело модуля как есть: значение атрибута на этапе
    # разворачивания макроса ещё не записано, и прочитать его оттуда нельзя.
    name = Keyword.fetch!(opts, :name)
    events = Keyword.fetch!(opts, :events)
    version = Keyword.get(opts, :version, @default_version)

    quote do
      @behaviour Core.Es.Projection
      @before_compile Core.Es.Projection

      @es_projection Core.Es.Projection.declaration!(
                       unquote(name),
                       unquote(events),
                       unquote(version)
                     )

      @doc false
      @spec __es_projection__() :: Core.Es.Projection.t()

      def __es_projection__,
        do: Map.merge(@es_projection, %{dao: unquote(dao), codec: unquote(codec)})
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    Enum.each([project: 1, clear: 0], &ensure_defined!(env, &1))
    nil
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

  # ===== проверка опций =====

  @doc false
  @spec declaration!(term(), term(), term()) :: %{
          name: String.t(),
          version: pos_integer(),
          events: [module()],
          streams: %{optional(String.t()) => stream()}
        }

  def declaration!(name, events, version) do
    name = name!(name)
    pairs = events!(events)

    %{
      name: name,
      version: version!(version),
      events: Enum.map(pairs, &elem(&1, 0)),
      streams: streams!(pairs)
    }
  end

  # ---

  defp name!(name) when is_binary(name) and name != "", do: name

  defp name!(name) do
    raise CompileError,
      description: "#{@label}: name: ожидается непустая строка, получено #{inspect(name)}"
  end

  defp version!(version) when is_integer(version) and version >= 1, do: version

  defp version!(version) do
    raise CompileError,
      description: "#{@label}: version: ожидается целое ≥ 1, получено #{inspect(version)}"
  end

  defp events!([_ | _] = events) do
    ensure_unique!(events)
    Enum.map(events, &{&1, event_codec!(&1)})
  end

  defp events!(events) do
    raise CompileError,
      description:
        "#{@label}: events: ожидается непустой список модулей событий, получено " <>
          inspect(events)
  end

  defp ensure_unique!(events) do
    case Enum.uniq(events -- Enum.uniq(events)) do
      [] ->
        :ok

      repeated ->
        raise CompileError,
          description: "#{@label}: events: модули объявлены дважды: #{inspect(repeated)}"
    end
  end

  defp event_codec!(mod) when is_atom(mod) and not is_nil(mod) do
    cond do
      not compiled?(mod) ->
        raise CompileError, description: "#{@label}: events: модуль #{inspect(mod)} не найден"

      function_exported?(mod, :__es_payload__, 0) ->
        codec!(mod, codec_name(Enum.drop(Module.split(mod), -1)))

      family?(mod) ->
        raise CompileError,
          description: "#{@label}: events: #{inspect(mod)} — семейство событий, объявляются модули событий"

      true ->
        raise CompileError,
          description: "#{@label}: events: #{inspect(mod)} — не модуль события (use Core.Es.Event)"
    end
  end

  defp event_codec!(other) do
    raise CompileError,
      description: "#{@label}: events: ожидается модуль события, получено #{inspect(other)}"
  end

  defp codec!(mod, codec) do
    cond do
      not compiled?(codec) ->
        raise CompileError,
          description:
            "#{@label}: events: кодек #{inspect(codec)} события #{inspect(mod)} не найден — " <>
              "кодек событий <Aggregate>.Event.<Name> — <Aggregate>.Event.Codec"

      not function_exported?(codec, :__es_type__, 0) ->
        raise CompileError,
          description:
            "#{@label}: events: #{inspect(codec)} события #{inspect(mod)} — не кодек событий " <>
              "с type: (use Core.Es.Event.Codec)"

      mod not in codec.__es_mods__() ->
        raise CompileError,
          description: "#{@label}: events: #{inspect(mod)} не объявлен в tags: #{inspect(codec)}"

      true ->
        codec
    end
  end

  defp family?(mod) do
    codec = codec_name(Module.split(mod))

    compiled?(codec) and function_exported?(codec, :__es_type__, 0) and
      codec.__codec_union__() == mod
  end

  # Кодек событий агрегата — `<Aggregate>.Event.Codec` рядом с модулями событий (`11-domain.md`).
  # Имя вычисляется на компиляции: `safe_concat` непригоден — атома имени модуля, которого нет,
  # ещё может не быть, а отсутствие кодека — ошибка компиляции с внятным текстом.
  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp codec_name(parts), do: Module.concat(parts ++ ["Codec"])

  defp compiled?(mod), do: match?({:module, _}, Code.ensure_compiled(mod))

  defp streams!(pairs) do
    pairs
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.reduce(%{}, fn {codec, mods}, streams -> put_stream!(streams, codec, mods) end)
  end

  defp put_stream!(streams, codec, mods) do
    type = codec.__es_type__()

    case Map.fetch(streams, type) do
      {:ok, %{codec: other}} ->
        raise CompileError,
          description:
            "#{@label}: events: тип агрегата #{inspect(type)} у двух кодеков: " <>
              "#{inspect(codec)} и #{inspect(other)}"

      :error ->
        Map.put(streams, type, %{codec: codec, tags: MapSet.new(mods, &codec.type/1)})
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

  # ===== ожидание =====

  @doc """
  Дождаться, пока проекция `projection` обработает последнее событие потока `aggregate_id`
  агрегата `aggregate`, — не дольше `timeout` мс.

  Зовётся после commit записи. Исходы, режимы и ошибки программиста — в `@moduledoc`, «Ожидание».
  """
  @spec await(module(), module(), struct(), non_neg_integer()) :: :ok | {:error, Error.t()}

  def await(projection, aggregate, %_{} = aggregate_id, timeout)
      when is_atom(projection) and is_atom(aggregate) and is_integer(timeout) and timeout >= 0,
      do: Await.run(projection, projection.__es_projection__(), aggregate, aggregate_id, timeout)
end
