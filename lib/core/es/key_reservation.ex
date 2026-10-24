defmodule Core.Es.KeyReservation do
  @moduledoc """
  Билдер модуля ключа `<Aggregate>.<Name>Key` — изменяемого уникального ключа event-sourced
  агрегата — и резерв ключа в `es_key_reservations` (`Core.Es.KeyReservation.Migration`).

      defmodule MyApp.Domain.<BC>.User.LoginKey do
        alias MyApp.Domain.<BC>.User
        alias MyApp.Domain.<BC>.User.Event

        use Core.Es.KeyReservation,
          scope: "user.login",
          aggregate: User,
          code: :login_taken

        @impl true
        def reservation(%Event.Created{payload: payload}), do: {:reserve, payload.login}
        def reservation(%Event.LoginChanged{payload: payload}), do: {:reserve, payload.login}
        def reservation(%Event.Blocked{}), do: :keep
        def reservation(%Event.Deleted{}), do: :release

        @impl true
        def to_key(%User.Login{} = login), do: User.Login.value(login)
      end

  Резервы держит репозиторий агрегата — `use Core.Es.Aggregate.Repo.Pg, key_reservations:
  [User.LoginKey]`: `append` ставит, переносит и снимает их в транзакции записи событий. Мотивация
  и отвергнутые варианты — `docs/adr/0018-mutable-key-reservation.md`.

  ## Колбэки

  - `reservation(event)` → `{:reserve, value} | :release | :keep` — что событие агрегата делает с
    его ключом в области: занимает ключ значения `value`, снимает ключ агрегата, не трогает ключ.
    Полноту по событиям кодека агрегата проверяет сборка модуля ключа («Opts»).
  - `to_key(value)` → `String.t() | [String.t(), ...]` — каноническая форма ключа: ключи
    сравниваются побайтно. Строка равна списку из одной части; составной ключ — список частей, и
    `["x:y", "z"]` не равен `["x", "y:z"]`.

  ## Резерв

  Строка `(scope, key) → aggregate_id`; у агрегата в области не больше одного ключа. `append`
  репозитория после записи событий обходит события пачки в её порядке, на каждое — модули
  `key_reservations:` в их порядке:

  - `{:reserve, value}` — снять прежний ключ агрегата в области и занять `to_key(value)`; ключ,
    уже занятый этим агрегатом, — успех, занятый другим — отказ;
  - `:release` — снять ключ агрегата в области, если он есть;
  - `:keep` — без запросов.

  Отказ — `errors.domain(behaviour, code, %{scope: scope})` репозитория: значения ключа в detail
  нет, логин и email — ПДн. Отказ не переводит транзакцию в aborted (`ON CONFLICT DO NOTHING`), но
  события и снятый прежний ключ к этому моменту уже записаны — транзакцию откатывает `append`.
  Ключ, который держит незакоммиченная транзакция, ждёт её исхода: commit — отказ, откат — резерв.
  Встречный перенос ключей двух агрегатов конкурентными транзакциями — deadlock Postgres:
  исключение у одной из них, отказ у другой.

  ### Порядок в пачке

  Шаг видит строки области, видимые его запросу: закоммиченные плюс изменения предыдущих шагов
  этой транзакции. Ключ, освобождённый `:release` или переносом агрегата на другое значение,
  свободен поэтому только для шагов **после** него: пачка, где ключ освобождает один агрегат, а
  занимает другой, MUST идти освобождением вперёд, иначе `{:reserve, value}` видит прежнего
  владельца и отказывает. Прямой обмен ключами двух агрегатов в одной пачке не проходит ни в каком
  порядке — освобождение и занятие идут там одним шагом — и разводится парковкой на третий ключ
  или разными пачками. События одного агрегата ограничения не несут: свой прежний ключ шаг снимает
  до вставки.

  ### Разбор отказа вставки

  `ON CONFLICT DO NOTHING` идёт без `conflict_target`, а такая форма глушит **оба** уникальных
  ограничения таблицы — и `(scope, key)`, и `(scope, aggregate_id)`. Какое сработало, различают
  строки области, прочитанные после отказа новым снимком:

  - строка нашего ключа называет владельца — свой ключ это успех, чужой отказ;
  - строка нашей пары `(scope, aggregate_id)` с другим ключом закоммитилась после `DELETE` этой
    попытки; её снимет `DELETE` следующей. Пара сталкивается у агрегатов разных видов с общим
    идентификатором из ключа (`docs/adr/0017-stream-id-from-key.md`) в одной области;
  - нет ни той, ни другой — ключ сняли между вставкой и чтением, и вставка следующей попытки его
    займёт.

  Повтор поэтому ровно один: обе причины снимает одна следующая попытка. Второй отказ подряд —
  не исход резерва, а аномалия состязания: `%Error{kind: :app, ns: :es}`,
  `code: :reservation_unresolved`, в detail — `scope`, `aggregate_id` и причина. Сужать
  `conflict_target` до `(scope, key)` нельзя: конфликт по паре стал бы исключением там, где
  следующая попытка доводит запись до конца.

  Владелец резерва — `aggregate_id` без типа агрегата. В области, общей у агрегатов разных видов,
  ключи сталкиваются независимо от вида, а `find/2` отдаёт id владельца в Prim идентификатора
  агрегата своего модуля ключа, даже если ключ занял агрегат другого вида.

  Резервы пишутся и читаются через `Core.Config.dao/0`, id агрегата дампит и грузит
  `Core.Config.codec/0` — как у `Core.Es.Store`.

  ## Ключ из ПДн (`personal: true`)

  Модуль ключа, значение которого — ПДн (email, телефон), объявляется `personal: true`
  (`docs/adr/0077-personal-key-reservation-index.md`). В `key` его строки — `text[]` из одной
  строки индекса, который считает порт хранилища ключей (`Core.Es.Personal.KeyStore`, `index`)
  над областью и частями `to_key/1`: одинаково на записи и в `find/2`, значение ключа в таблицу не
  попадает. Остальное — как у ключа без флага: занятость, перенос, `:release`, порядок в пачке.

  - `append` считает индексы всех шагов `{:reserve, value}` модулей с `personal: true` пачки одним
    вызовом порта до записи резервов; пачка без таких шагов порт не зовёт. Сбой хранилища ключей —
    `{:error, %Core.Error{kind: :app}}` на всю пачку: `append` откатывает транзакцию, а
    `Core.Es.Transact` этот отказ не повторяет.
  - `find/2` зовёт порт на каждый вызов; сбой хранилища ключей — `Core.Exc`, как сбой базы под
    его SQL.
  - `{:reserve, value}`, где `value` — Prim с `personal: true`, у модуля без `personal: true` —
    `ArgumentError` на `append`: забытый флаг оставил бы ПДн в резерве открытыми. Prim, вложенный
    в значение, проверка не видит.

  Снимает резерв субъекта событие агрегата-владельца с ответом `:release` в транзакции уничтожения
  ключа субъекта (`Core.Es.Personal.destroy_key/3`): сама операция резервы не трогает. Индекс
  снятого ключа остаётся в мёртвом кортеже, WAL-архиве и копиях; без секрета индекса он
  непрозрачен.

  ## Telemetry

  `[:es, :key_reservation]` (`Core.Telemetry.event/1`) — на итоговый исход каждого
  `{:reserve, value}`, а не на попытку повтора: измерение `count` (1); метаданные `scope` (область
  модуля ключа) и `result` — `:reserved` (ключ за агрегатом), `:taken` (занят другим),
  `:unresolved` (`:reservation_unresolved`). `:release` и `:keep` событий не дают. Исход шага не
  зависит от судьбы транзакции: `:reserved` засчитан и тогда, когда `append` откатывает её отказом
  следующего шага, а повтор команды после отказа записи (`Core.Es.Transact`) даёт новый исход. Значения ключа и `aggregate_id` в метаданных нет — ПДн и растущая
  кардинальность. Счётчик — `Core.Es.PromEx`, `key_reservation.total{scope, result}`.

  ## Генерируемые функции

  - `find(value, context)` → `Agg.ID.t() | nil` — агрегат, занявший ключ `to_key(value)`; `nil` —
    ключ свободен. Результат сужен до `%Agg.ID{} | nil`; нечитаемый id — исключение загрузки
    фасадом, у модуля с `personal: true` сбой хранилища ключей — `Core.Exc`.

  ## Opts

  Все опции — литералы (`docs/rules/20-agreements.md`, «Опции `use`»): атрибут или вызов
  функции в опции — `CompileError` «ожидается литерал».

  - `scope:` — область ключа, непустая строка
  - `aggregate:` — event-sourced агрегат (`use Core.Es.Aggregate`); кодек событий и Prim
    идентификатора (литерал в `find/2`) — из его кодека
  - `code:` — код отказа в каталоге ошибок репозитория, атом
  - `personal:` — ключ из ПДн («Ключ из ПДн»), boolean, по умолчанию `false`; ставится только на
    область без записанных резервов

  На компиляции `CompileError`: нет обязательной или неизвестная опция, `scope:` — не непустая
  строка, `aggregate:` — не event-sourced агрегат, `code:` — не атом или `:version_mismatch`
  (конфликт записи, который процесс агрегата повторяет), `personal:` — не boolean. Сборка
  репозитория (`Core.Es.Aggregate.Repo.Pg`) сверяет `aggregate:` ключа со своим агрегатом и clause
  `code:` в `errors:`.

  Сборка проверяет `reservation/1` по кодеку агрегата: на каждое событие макрос генерирует
  функцию-проверку (`Core.Es.Check`) `"reservation/1 принимает <Event>"` — литеральный вызов
  `reservation(%Event.Mod{payload: %Payload{}} = event)`. Событие без clause и опечатка в поле
  нагрузки, не суженной паттерном, — предупреждение на строке `use` модуля ключа.

  Макрос занимает в вызывающем модуле имена `@es_key_reservation`, `find/2`,
  `__es_key_reservation__/0` и функций-проверок `"reservation/1 принимает <Event>"/1`.
  """

  import Ecto.Query

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Es.KeyReservation.Schema
  alias Core.Es.Personal.Port
  alias Core.Exc
  alias Core.Helper
  alias Core.Prim
  alias Core.Result
  alias Core.Telemetry

  require Error

  @label "Es.KeyReservation"
  @required_keys ~w(scope aggregate code)a
  @optional_keys ~w(personal)a
  @expression_keys []

  # Предел повторов резерва: обе причины отказа снимаются одной следующей попыткой — чужую строку
  # нашей пары `(scope, aggregate_id)` снесёт её `DELETE`, исчезнувший ключ займёт её вставка.
  # Второй отказ подряд — аномалия состязания, а не исход резерва.
  @reserve_retries 1

  @typedoc "Объявление модуля ключа: `__es_key_reservation__/0`."
  @type declaration :: %{
          module: module(),
          scope: String.t(),
          aggregate: module(),
          event_codec: module(),
          id: module(),
          code: atom(),
          personal: boolean()
        }

  @typedoc "Ключ — каноническая форма `to_key/1`."
  @type key :: String.t() | [String.t(), ...]

  @doc "Что событие агрегата делает с его ключом в области."
  @callback reservation(event :: Es.Event.t()) :: {:reserve, value :: term()} | :release | :keep

  @doc "Каноническая форма ключа значения `value`."
  @callback to_key(value :: term()) :: key()

  # ===== объявление =====

  @doc "Объявить модуль изменяемого уникального ключа event-sourced агрегата."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)

    declaration =
      opts
      |> Helper.Opts.literal!(@expression_keys, @label)
      |> parse!()
      |> Map.put(:module, __CALLER__.module)

    checks = checks(declaration, __CALLER__.line)

    quote generated: true do
      unquote_splicing(checks)

      @behaviour Core.Es.KeyReservation

      @es_key_reservation unquote(Macro.escape(declaration))

      @doc false
      @spec __es_key_reservation__() :: Core.Es.KeyReservation.declaration()

      def __es_key_reservation__, do: @es_key_reservation

      @doc "Агрегат, занявший ключ значения `value`; `nil` — ключ свободен."
      @spec find(term(), Core.Context.t()) :: unquote(declaration.id).t() | nil

      def find(value, %Core.Context{} = context) do
        case Core.Es.KeyReservation.find(@es_key_reservation, to_key(value), context) do
          %unquote(declaration.id){} = id -> id
          nil -> nil
        end
      end
    end
  end

  # ---

  defp parse!(opts) do
    aggregate = Helper.Opts.module!(opts, :aggregate, @label, exports: [__es_event_codec__: 0])
    event_codec = Es.Store.Opts.event_codec!(aggregate.__es_event_codec__(), @label)

    %{
      scope: scope!(opts),
      aggregate: aggregate,
      event_codec: event_codec,
      id: event_codec.__es_aggregate_id__(),
      code: code!(opts),
      personal: personal!(opts)
    }
  end

  # Функции-проверки полноты `reservation/1` (`Core.Es.Check`) по событиям кодека агрегата.
  defp checks(%{event_codec: event_codec}, line) do
    for event <- Enum.sort(event_codec.__es_mods__()) do
      args = [quote(do: unquote(Es.Check.event_pattern(event)) = event)]
      Es.Check.define("reservation/1 принимает", event, args, quote(do: reservation(event)), line)
    end
  end

  defp scope!(opts) do
    case Helper.Opts.binary!(opts, :scope, @label) do
      "" -> Helper.Opts.reject!("#{@label}: scope", "ожидается непустая строка, получено \"\"")
      scope -> scope
    end
  end

  defp code!(opts) do
    case Helper.Opts.atom!(opts, :code, @label) do
      :version_mismatch ->
        Helper.Opts.reject!("#{@label}: code", ":version_mismatch — код конфликта записи, а не отказа резерва")

      code ->
        code
    end
  end

  defp personal!(opts) do
    case Keyword.get(opts, :personal, false) do
      personal when is_boolean(personal) ->
        personal

      other ->
        Helper.Opts.reject!("#{@label}: personal", "ожидается boolean, получено #{inspect(other)}")
    end
  end

  # ===== сборка репозитория =====

  # Объявления модулей `key_reservations:`, сверенные с репозиторием; `label` — имя его builder'а.
  @doc false
  @spec declarations!(term(), module(), module(), String.t()) :: [declaration()]

  def declarations!(keys, aggregate, errors, label)
      when is_atom(aggregate) and is_atom(errors) and is_binary(label) do
    declarations =
      keys
      |> modules!(label)
      |> Enum.map(&declaration!(&1, aggregate, errors, label))

    ensure_unique_scopes!(declarations, label)
    declarations
  end

  # ---

  defp modules!(keys, label) when is_list(keys) do
    Enum.map(keys, fn key ->
      Helper.Opts.module!([key_reservations: key], :key_reservations, label, exports: [__es_key_reservation__: 0])
    end)
  end

  defp modules!(keys, label) do
    Helper.Opts.reject!("#{label}: key_reservations", "ожидается список модулей ключа, получено #{inspect(keys)}")
  end

  defp declaration!(module, aggregate, errors, label) do
    declaration = module.__es_key_reservation__()

    if declaration.aggregate != aggregate do
      Helper.Opts.reject!(
        "#{label}: key_reservations: aggregate",
        "#{inspect(declaration.aggregate)} у #{inspect(module)} не равен агрегату репозитория #{inspect(aggregate)}"
      )
    end

    ensure_code!(errors, declaration, label)
    declaration
  end

  defp ensure_code!(errors, %{module: module, code: code}, label),
    do: Helper.Opts.error_code!(errors, code, "#{label}: key_reservations: #{inspect(module)}: code")

  defp ensure_unique_scopes!(declarations, label) do
    declarations
    |> Enum.group_by(& &1.scope, & &1.module)
    |> Enum.find(fn {_scope, modules} -> length(modules) > 1 end)
    |> case do
      nil ->
        :ok

      {scope, modules} ->
        Helper.Opts.reject!(
          "#{label}: key_reservations",
          "область #{inspect(scope)} повторяется: #{inspect(modules)}"
        )
    end
  end

  # ===== поиск =====

  @doc false
  @spec find(declaration(), key(), Context.t()) :: struct() | nil

  def find(%{scope: scope, id: id} = declaration, key, %Context{}) do
    stored = stored_key!(declaration, parts(key))
    query = from(r in Schema, where: r.scope == ^scope and r.key == ^stored, select: r.aggregate_id)

    case Config.dao().one(query) do
      nil -> nil
      aggregate_id -> Config.codec().load!(id, aggregate_id)
    end
  end

  # ---

  # Сбой хранилища ключей — исключение, как сбой базы под SQL поиска.
  defp stored_key!(%{personal: false}, key), do: key

  defp stored_key!(%{personal: true, scope: scope}, key) do
    case Port.index([{scope, key}]) do
      {:ok, [index]} -> [index]
      {:error, %Error{} = error} -> raise Exc, error
    end
  end

  # ===== запись =====

  # Резервы по событиям пачки — `append` репозитория после записи событий; `taken` строит ошибку
  # отказа из `code:` модуля ключа и detail `%{scope: scope}`.
  @doc false
  @spec append([declaration()], [Es.Event.t()], Context.t(), (atom(), map() -> Error.t())) ::
          Result.unit()

  def append(declarations, events, context, taken)

  def append([], events, %Context{}, taken) when is_list(events) and is_function(taken, 2), do: :ok

  def append([_ | _] = declarations, events, %Context{}, taken) when is_list(events) and is_function(taken, 2) do
    steps = for event <- events, declaration <- declarations, do: {declaration, event, action(declaration, event)}

    with {:ok, steps} <- index(steps) do
      case write(steps, Config.codec()) do
        :ok -> :ok
        {:taken, declaration} -> {:error, taken.(declaration.code, %{scope: declaration.scope})}
        {:unresolved, declaration, aggregate_id, reason} -> {:error, unresolved(declaration, aggregate_id, reason)}
      end
    end
  end

  # ---

  defp action(%{module: module} = declaration, event) do
    case module.reservation(event) do
      {:reserve, value} -> {:reserve, parts(module.to_key(ensure_flagged!(declaration, value)))}
      :release -> :release
      :keep -> :keep
    end
  end

  # Вложенный Prim проверка не видит: признак — только у значения `{:reserve, value}` целиком.
  defp ensure_flagged!(%{personal: false, module: module}, %prim{} = value) do
    if Prim.prim?(prim) and prim.__domain_personal__() do
      raise ArgumentError,
            "#{inspect(module)}: {:reserve, value} с Prim personal: true #{inspect(prim)} у модуля ключа " <>
              "без personal: true — значение легло бы в резерв открытым"
    end

    value
  end

  defp ensure_flagged!(_declaration, value), do: value

  # Индексы ключей из ПДн пачки — одним вызовом порта до записи; отказ — на всю пачку.
  defp index(steps) do
    case for({%{personal: true, scope: scope}, _event, {:reserve, key}} <- steps, do: {scope, key}) do
      [] -> {:ok, steps}
      items -> with {:ok, indexes} <- Port.index(items), do: {:ok, indexed(steps, indexes)}
    end
  end

  defp indexed([], []), do: []

  defp indexed([{%{personal: true} = declaration, event, {:reserve, _key}} | steps], [index | indexes]),
    do: [{declaration, event, {:reserve, [index]}} | indexed(steps, indexes)]

  defp indexed([step | steps], indexes), do: [step | indexed(steps, indexes)]

  defp write([], _codec), do: :ok

  defp write([{declaration, event, action} | steps], codec) do
    aggregate_id = codec.dump(event.aggregate_id)

    case write_step(declaration, action, aggregate_id) do
      :ok -> write(steps, codec)
      :taken -> {:taken, declaration}
      {:unresolved, reason} -> {:unresolved, declaration, aggregate_id, reason}
    end
  end

  defp write_step(%{scope: scope}, {:reserve, key}, aggregate_id), do: reserve_reported(scope, key, aggregate_id)
  defp write_step(%{scope: scope}, :release, aggregate_id), do: delete(keys_of(scope, aggregate_id))
  defp write_step(_declaration, :keep, _aggregate_id), do: :ok

  defp reserve_reported(scope, key, aggregate_id) do
    resolved = reserve(scope, key, aggregate_id, 0)
    emit(scope, resolved)
    resolved
  end

  # Сначала снимается прежний ключ агрегата: иначе вставка упёрлась бы в `(scope, aggregate_id)`.
  defp reserve(scope, key, aggregate_id, retries) do
    :ok = delete(where(keys_of(scope, aggregate_id), [r], r.key != ^key))
    row = %{scope: scope, key: key, aggregate_id: aggregate_id}

    case Config.dao().insert_all(Schema, [row], on_conflict: :nothing) do
      {1, _rows} -> :ok
      {0, _rows} -> refused(scope, key, aggregate_id, retries)
    end
  end

  defp refused(scope, key, aggregate_id, retries) do
    case outcome(rows_of(scope, key, aggregate_id), key, retries) do
      :retry -> reserve(scope, key, aggregate_id, retries + 1)
      resolved -> resolved
    end
  end

  # Строки области, которые могли отвергнуть вставку, — новым снимком: он видит и транзакцию,
  # commit которой вставка ждала.
  defp rows_of(scope, key, aggregate_id) do
    from(r in Schema,
      where: r.scope == ^scope,
      where: r.key == ^key or r.aggregate_id == type(^aggregate_id, :binary_id),
      select: %{key: r.key, mine?: r.aggregate_id == type(^aggregate_id, :binary_id)}
    )
    |> Config.dao().all()
  end

  defp emit(scope, resolved) do
    :telemetry.execute(
      Telemetry.event([:es, :key_reservation]),
      %{count: 1},
      %{scope: scope, result: result(resolved)}
    )
  end

  defp result(:ok), do: :reserved
  defp result(:taken), do: :taken
  defp result({:unresolved, _reason}), do: :unresolved

  defp unresolved(declaration, aggregate_id, reason) do
    Error.app(
      code: :reservation_unresolved,
      ns: :es,
      message: "Резерв ключа не разрешён: конкурентная запись в области",
      detail: %{scope: declaration.scope, aggregate_id: aggregate_id, reason: reason}
    )
  end

  defp keys_of(scope, aggregate_id),
    do: from(r in Schema, where: r.scope == ^scope and r.aggregate_id == type(^aggregate_id, :binary_id))

  defp delete(query) do
    {_count, nil} = Config.dao().delete_all(query)
    :ok
  end

  # ===== разбор отказа =====

  # `ON CONFLICT DO NOTHING` без `conflict_target` глушит **оба** уникальных ограничения таблицы,
  # поэтому какое из них сработало, различают строки области: строка нашего ключа называет
  # владельца, а строка нашей пары `(scope, aggregate_id)` с другим ключом означает, что она
  # закоммитилась после нашего `DELETE`. Нет ни той, ни другой — ключ сняли между вставкой и
  # чтением. Обе причины снимает следующая попытка, поэтому предел — `@reserve_retries`.
  @doc false
  @spec outcome([%{key: key(), mine?: boolean()}], key(), non_neg_integer()) ::
          :ok | :taken | :retry | {:unresolved, :pair_taken | :key_vanished}

  def outcome(rows, key, retries) when is_list(rows) and is_integer(retries) and retries >= 0 do
    case Enum.find(rows, &(&1.key == key)) do
      %{mine?: true} -> :ok
      %{mine?: false} -> :taken
      nil -> retry_or_unresolved(rows, retries)
    end
  end

  # ---

  defp retry_or_unresolved(_rows, retries) when retries < @reserve_retries, do: :retry
  defp retry_or_unresolved([], _retries), do: {:unresolved, :key_vanished}
  defp retry_or_unresolved([_ | _], _retries), do: {:unresolved, :pair_taken}

  # ===== общее =====

  defp parts(key) when is_binary(key), do: [key]
  defp parts([_ | _] = key), do: key
end
