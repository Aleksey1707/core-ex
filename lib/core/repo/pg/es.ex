defmodule Core.Repo.Pg.Es do
  @moduledoc """
  Билдер write-репозитория агрегата с событиями и outbox.

      use Core.Repo.Pg.Es,
        behaviour: MyApp.Domain.<BC>.Common.Role.Repo,
        schema: Schema,
        to_entity: &Schema.to_entity!/1,
        to_model: &Schema.to_model!/1,
        to_id: &Schema.dump_id/1,
        query: Specs.base_query(),
        default_filters: &Specs.default/1,
        shadow_copy?: true,
        id: Role.ID,
        entity: Role,
        errors: Role.Errors,
        constraint_errors: [unique: [name: :already_exists]],
        event_repo: Role.Event.Repo,
        outbox: Role.Outbox,
        children: [[schema: Schema.Permission, fk: :role_id]]

  Надстройка над `Core.Repo.Pg`: свои опции макрос забирает себе, остальные передаёт
  в `use Repo.Pg` как есть, затем переопределяет `insert/3`, `update/3` и `save/3`.
  Набор ключей проверяется целиком здесь — чтобы опечатка в любой опции называла `Repo.Pg.Es`.

  Каждая запись идёт одной транзакцией: строка агрегата → дочерние строки → flush событий
  в event store и outbox. Дочерние строки пишет `Core.Repo.Pg.Children` — точечно, а не
  перезаписью всей коллекции:

  | Путь | Запросов на дочернюю таблицу |
  |---|---|
  | `insert/3` — родитель только что создан | `insert_all` (без `on_conflict`) |
  | `update/3` с эталоном (shadow copy) | 0..2: `delete_all` исчезнувших ключей + upsert новых и изменившихся |
  | `update/3` без эталона | 2: `delete_all` всего, чего нет в наборе, + upsert набора |

  Возвращается **входной** агрегат с очищенными событиями: строка из БД после `insert` не
  содержит прогруженных `has_many`, и вернуть её означало бы потерять детей. Он же кладётся
  эталоном в `Repo.Sc` (`Repo.Pg.put_baseline/3`) — иначе следующая запись считала бы diff
  дочерних строк от устаревшей копии.

  `save/3` переопределяется обязательно: `Repo.Pg.save/4` зовёт `Repo.Pg.insert/update`,
  а не переопределённые в модуле, то есть записал бы строку без детей и без событий.

  ## Opts (сверх опций `Repo.Pg`)

  - `event_repo:` — модуль **behaviour** репозитория событий; реализация резолвится
    макросом через `Application.compile_env!(Core.Config.otp_app(), <behaviour>)`,
    то есть в app-env приложения-потребителя (`config :core, otp_app: :my_app`).
    Это единственное место, где Core читает конфигурацию не из `:core`: DI доменных
    репозиториев — контракт хоста, и жить он должен под его именем
  - `outbox:` — `<Aggregate>.Outbox` (маппинг событий в записи outbox)
  - `children:` — список описаний дочерних таблиц:
    - `schema:` — Ecto-схема с `to_models/1` (обязательно)
    - `fk:` — колонка внешнего ключа на агрегат (обязательно)
    - `key:` — колонки, уникально идентифицирующие строку внутри агрегата; по умолчанию
      составной первичный ключ схемы без `fk`
    - `constraint_errors:` — `[<имя constraint'а в БД>: <код ошибки>]`; у дочерних схем нет
      `changeset/2`, поэтому маппинг идёт по имени constraint'а, а не по полю. Коды
      проверяются на этапе компиляции по модулю `errors:`, имена — тестом
      `test/<app>/repo/constraint_errors_test.exs`. FK на **сам агрегат** (колонка `fk:`)
      не мапится: строка родителя пишется той же транзакцией раньше, нарушить его нечем

  ## Контракты дочерней схемы

  - `to_models/1` возвращает **все** колонки таблицы: пропущенную обнулит `on_conflict: {:replace, ...}`.
  - `query:` прогружает дочерние ассоциации целиком и без фильтров: эталон в `Repo.Sc` — это
    прочитанный агрегат, и неполный эталон даст diff с пропущенными удалениями.

  Опция `entity:` обязательна (в `Repo.Pg` она опциональна) — по ней строятся заголовки
  переопределённых функций.

  Макрос занимает имена `@es_event_repo`, `@es_outbox`, `@es_outbox_repo`, `@es_children`.
  """

  alias Core.Config
  alias Core.Helper

  @label "Repo.Pg.Es"
  @children_label "#{@label}: children"
  @own_keys ~w(event_repo outbox children)a
  @required_callbacks ~w(insert update save)a

  @doc "Реализовать write-репозиторий агрегата с событиями через PostgreSQL."
  defmacro __using__(opts) do
    lit = Macro.expand_literals(opts, __CALLER__)
    cfg = validate_opts!(lit)
    pg_opts = Keyword.drop(opts, @own_keys)
    dao = Keyword.get(lit, :repo) || Config.dao()

    quote do
      use Core.Repo.Pg, unquote(pg_opts)

      @es_event_repo Application.compile_env!(
                       unquote(Config.otp_app()),
                       unquote(cfg.event_repo)
                     )
      @es_outbox unquote(cfg.outbox)
      @es_outbox_repo Application.compile_env!(:core, Core.Outbox.Repo)
      @es_children unquote(Macro.escape(cfg.children))

      @doc false
      @spec __children_constraint_errors__() :: [map()]

      def __children_constraint_errors__, do: @es_children

      @doc "Вставить агрегат с дочерними строками; сбросить события в event store и outbox."
      @impl true
      def insert(%unquote(cfg.entity){} = entity, %Core.Context{} = context, opts \\ [])
          when is_list(opts) do
        Core.Helper.Transact.run(
          unquote(dao),
          fn ->
            with :ok <- Core.Repo.Pg.write_insert(@pg, entity, context, opts),
                 :ok <- Core.Repo.Pg.Children.insert(@pg, @es_children, entity, opts),
                 :ok <- flush_events(entity, context, opts) do
              persisted(entity, context)
            end
          end,
          opts
        )
      end

      @doc "Обновить агрегат с дочерними строками; сбросить события в event store и outbox."
      @impl true
      def update(%unquote(cfg.entity){} = entity, %Core.Context{} = context, opts \\ [])
          when is_list(opts) do
        Core.Helper.Transact.run(
          unquote(dao),
          fn ->
            baseline = Core.Repo.Pg.baseline(@pg, entity, context)
            check_events_for_change!(entity, baseline)

            with :ok <- Core.Repo.Pg.write_update(@pg, entity, context, opts),
                 :ok <-
                   Core.Repo.Pg.Children.sync(@pg, @es_children, entity, baseline, opts),
                 :ok <- flush_events(entity, context, opts) do
              persisted(entity, context)
            end
          end,
          opts
        )
      end

      @doc "Сохранить агрегат (insert или update) со сбросом событий."
      @impl true
      def save(%unquote(cfg.entity){} = entity, %Core.Context{} = context, opts \\ [])
          when is_list(opts) do
        # Проверка существования и запись — в одной транзакции: между ними строку
        # могли создать или удалить, и ветка ушла бы не туда.
        Core.Helper.Transact.run(
          unquote(dao),
          fn ->
            case known_to_exist?(entity, context, opts) do
              {:ok, true} -> __MODULE__.update(entity, context, opts)
              {:ok, false} -> __MODULE__.insert(entity, context, opts)
            end
          end,
          opts
        )
      end

      defoverridable insert: 2, insert: 3, update: 2, update: 3, save: 2, save: 3

      # Эталон кладётся после commit: при откате транзакции он остался бы «как будто
      # записано», и следующая запись по этому контексту молча пропустила бы детей.
      defp persisted(entity, context) do
        written = %{entity | events: Core.Es.Events.clear(entity.events)}

        Core.Helper.AfterCommit.register(fn ->
          Core.Repo.Pg.put_baseline(@pg, written, context)
        end)

        {:ok, written}
      end

      defp known_to_exist?(entity, context, opts) do
        if Core.Repo.Pg.baseline(@pg, entity, context) != nil,
          do: {:ok, true},
          else: Core.Repo.Pg.exists?(@pg, entity.id, :current, context, opts)
      end

      # Защита агрегата с событиями от потерянного обновления — сам факт события:
      # unique-индекс `(aggregate_id, aggregate_version)` в event store ловит конкурентную
      # запись, а `optimistic_lock` на строке агрегата не используется. Мутация, изменившая
      # состояние, но не породившая события, эту защиту обходит молча.
      defp check_events_for_change!(entity, baseline) do
        if Core.Es.Events.empty?(entity.events) and not is_nil(baseline) and
             baseline != entity do
          raise ArgumentError,
                "#{inspect(unquote(cfg.entity))}: состояние изменено без события — " <>
                  "запись обошла бы проверку конкурентности event store"
        end

        :ok
      end

      defp flush_events(entity, context, opts) do
        if Core.Es.Events.empty?(entity.events),
          do: :ok,
          else: do_flush_events(Core.Es.Events.to_list(entity.events), context, opts)
      end

      defp do_flush_events(events, context, opts) do
        with {:ok, records} <- @es_outbox.from_events(events),
             :ok <- @es_event_repo.append(events, context, opts) do
          @es_outbox_repo.append(records, context, opts)
        end
      end
    end
  end

  @doc false
  @spec own_keys() :: [atom()]

  def own_keys, do: @own_keys

  # ---

  defp validate_opts!(opts) do
    unless Keyword.keyword?(opts) do
      raise CompileError,
        description:
          "#{@label}: ожидается литеральный keyword opts, получено #{Macro.to_string(opts)}"
    end

    Helper.Opts.validate!(
      opts,
      Core.Repo.Pg.required_keys() ++ ~w(to_entity to_model event_repo outbox entity)a,
      Core.Repo.Pg.optional_keys() ++ ~w(children)a,
      @label
    )

    %{
      entity: Helper.Opts.module!(opts, :entity, @label),
      event_repo: Helper.Opts.module!(opts, :event_repo, @label, exports: [behaviour_info: 1]),
      outbox: Helper.Opts.module!(opts, :outbox, @label, exports: [from_events: 1]),
      children: children!(opts),
      behaviour: behaviour!(opts)
    }
  end

  defp behaviour!(opts) do
    behaviour = Helper.Opts.module!(opts, :behaviour, @label)
    callbacks = behaviour.behaviour_info(:callbacks)
    missing = Enum.reject(@required_callbacks, &List.keymember?(callbacks, &1, 0))

    if missing != [] do
      raise CompileError,
        description:
          "#{@label}: behaviour #{inspect(behaviour)} должен объявлять #{inspect(missing)}"
    end

    behaviour
  end

  defp children!(opts) do
    errors = Keyword.get(opts, :errors)

    opts
    |> Keyword.get(:children, [])
    |> Enum.map(&child!(&1, errors))
  end

  defp child!(child, errors) when is_list(child) do
    Helper.Opts.validate!(child, ~w(schema fk)a, ~w(key constraint_errors)a, @children_label)

    schema =
      Helper.Opts.module!(child, :schema, @children_label, exports: [to_models: 1, __schema__: 1])

    fk = fk!(Keyword.fetch!(child, :fk), schema)
    key = key!(child, schema, fk)

    %{
      schema: schema,
      fk: fk,
      key: key,
      conflict_target: [fk | key],
      replace: schema.__schema__(:fields) -- [fk | key],
      constraint_errors: constraint_errors!(child, errors)
    }
  end

  defp child!(other, _errors) do
    raise CompileError,
      description: "#{@label}: children: ожидается keyword, получено #{inspect(other)}"
  end

  defp fk!(fk, schema) when is_atom(fk) and not is_nil(fk) do
    unless fk in schema.__schema__(:fields) do
      raise CompileError,
        description: "#{@children_label}: fk: колонки #{inspect(fk)} нет в #{inspect(schema)}"
    end

    fk
  end

  defp fk!(other, _schema) do
    raise CompileError,
      description: "#{@children_label}: fk: ожидается атом, получено #{inspect(other)}"
  end

  defp key!(child, schema, fk) do
    child
    |> Keyword.get_lazy(:key, fn -> default_key!(schema, fk) end)
    |> validate_key!(schema, fk)
  end

  defp default_key!(schema, fk) do
    case schema.__schema__(:primary_key) -- [fk] do
      [] ->
        raise CompileError,
          description:
            "#{@children_label}: schema: у #{inspect(schema)} нет первичного ключа помимо " <>
              "#{inspect(fk)} — задайте key:"

      key ->
        key
    end
  end

  defp validate_key!(key, schema, fk) when is_list(key) and key != [] do
    unknown = Enum.reject(key, &(&1 in schema.__schema__(:fields)))

    if unknown != [] do
      raise CompileError,
        description:
          "#{@children_label}: key: колонок #{inspect(unknown)} нет в #{inspect(schema)}"
    end

    if fk in key do
      raise CompileError,
        description: "#{@children_label}: key: #{inspect(fk)} — это fk, в ключе он лишний"
    end

    key
  end

  defp validate_key!(other, _schema, _fk) do
    raise CompileError,
      description:
        "#{@children_label}: key: ожидается непустой список колонок, получено #{inspect(other)}"
  end

  defp constraint_errors!(child, errors) do
    child
    |> Keyword.get(:constraint_errors, [])
    |> normalize_constraint_errors!()
    |> validate_constraint_codes!(errors)
  end

  defp normalize_constraint_errors!(raw) when is_list(raw) do
    unless Keyword.keyword?(raw) do
      raise CompileError,
        description:
          "#{@children_label}: constraint_errors: ожидается keyword [constraint: code], " <>
            "получено #{inspect(raw)}"
    end

    Enum.reduce(raw, %{}, &put_constraint_error!/2)
  end

  defp normalize_constraint_errors!(other) do
    raise CompileError,
      description:
        "#{@children_label}: constraint_errors: ожидается keyword, получено #{inspect(other)}"
  end

  defp put_constraint_error!({constraint, code}, acc) when is_atom(code) and not is_nil(code) do
    name = Atom.to_string(constraint)

    if Map.has_key?(acc, name) do
      raise CompileError,
        description: "#{@children_label}: constraint_errors: дубликат #{inspect(constraint)}"
    end

    Map.put(acc, name, code)
  end

  defp put_constraint_error!({constraint, other}, _acc) do
    raise CompileError,
      description:
        "#{@children_label}: constraint_errors: #{constraint}: ожидается атом кода, " <>
          "получено #{inspect(other)}"
  end

  defp validate_constraint_codes!(mapping, _errors) when map_size(mapping) == 0, do: mapping

  defp validate_constraint_codes!(mapping, errors) do
    module = Helper.Opts.module!([errors: errors], :errors, @children_label, exports: [domain: 3])
    Core.Repo.Pg.validate_constraint_error_codes!(module, mapping)

    mapping
  end
end
