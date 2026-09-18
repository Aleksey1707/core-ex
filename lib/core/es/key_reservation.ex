defmodule Core.Es.KeyReservation do
  @moduledoc """
  Билдер модуля ключа `<Aggregate>.<Name>Key` — изменяемого уникального ключа event-sourced
  агрегата — и резерв ключа в `es_key_reservations` (`Core.Es.KeyReservation.Migration`).

      defmodule MyApp.Domain.<BC>.Common.User.LoginKey do
        alias MyApp.Domain.<BC>.Common.User
        alias MyApp.Domain.<BC>.Common.User.Event

        use Core.Es.KeyReservation,
          scope: "user.login",
          event: User.Event,
          id: User.ID,
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
    Полноту по событиям кодека проверяет сборка репозитория.
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
  ключи сталкиваются независимо от вида, а `find/2` отдаёт id владельца в Prim `id:` своего модуля
  ключа, даже если ключ занял агрегат другого вида.

  Резервы пишутся и читаются через `Core.Config.dao/0`, id агрегата дампит и грузит
  `Core.Config.codec/0` — как у `Core.Es.Store`.

  ## Генерируемые функции

  - `find(value, context)` → `Agg.ID.t() | nil` — агрегат, занявший ключ `to_key(value)`; `nil` —
    ключ свободен. Результат сужен до `%Agg.ID{} | nil`; нечитаемый id — исключение загрузки
    фасадом.

  ## Opts

  - `scope:` — область ключа, непустая строка
  - `event:` — семейство событий агрегата (`event:` его кодека)
  - `id:` — Prim идентификатора агрегата
  - `code:` — код отказа в каталоге ошибок репозитория, атом

  На компиляции `CompileError`: нет обязательной или неизвестная опция, `scope:` — не непустая
  строка, `event:` или `id:` — не модуль, `code:` — не атом или `:version_mismatch` (конфликт
  записи, который процесс агрегата повторяет). Сверку с агрегатом — семейство
  событий, `id:`, clause `code:` в `errors:`, полноту `reservation/1` — делает сборка репозитория
  (`Core.Es.Aggregate.Repo.Pg`).

  Макрос занимает в вызывающем модуле имена `@es_key_reservation`, `find/2` и
  `__es_key_reservation__/0`.
  """

  import Ecto.Query

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Es.KeyReservation.Schema
  alias Core.Helper

  require Error

  @label "Es.KeyReservation"
  @required_keys ~w(scope event id code)a
  @optional_keys []

  # Предел повторов резерва: обе причины отказа снимаются одной следующей попыткой — чужую строку
  # нашей пары `(scope, aggregate_id)` снесёт её `DELETE`, исчезнувший ключ займёт её вставка.
  # Второй отказ подряд — аномалия состязания, а не исход резерва.
  @reserve_retries 1

  @typedoc "Объявление модуля ключа: `__es_key_reservation__/0`."
  @type declaration :: %{
          module: module(),
          scope: String.t(),
          event: module(),
          id: module(),
          code: atom()
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
    declaration =
      opts
      |> Macro.expand_literals(__CALLER__)
      |> validate_opts!()
      |> Map.put(:module, __CALLER__.module)

    quote generated: true do
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

  defp validate_opts!(opts) do
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)

    %{
      scope: scope!(opts),
      event: Helper.Opts.module!(opts, :event, @label),
      id: Helper.Opts.module!(opts, :id, @label),
      code: code!(opts)
    }
  end

  defp scope!(opts) do
    case Helper.Opts.binary!(opts, :scope, @label) do
      "" -> raise CompileError, description: "#{@label}: scope: ожидается непустая строка, получено \"\""
      scope -> scope
    end
  end

  defp code!(opts) do
    case Helper.Opts.atom!(opts, :code, @label) do
      :version_mismatch ->
        raise CompileError,
          description: "#{@label}: code: :version_mismatch — код конфликта записи, а не отказа резерва"

      code ->
        code
    end
  end

  # ===== сборка репозитория =====

  # Объявления модулей `key_reservations:`, сверенные с репозиторием; `label` — имя его builder'а.
  @doc false
  @spec declarations!(term(), module(), module(), module(), String.t()) :: [declaration()]

  def declarations!(keys, event_codec, id, errors, label)
      when is_atom(event_codec) and is_atom(id) and is_atom(errors) and is_binary(label) do
    declarations =
      keys
      |> modules!(label)
      |> Enum.map(&declaration!(&1, event_codec, id, errors, label))

    ensure_unique_scopes!(declarations, label)
    declarations
  end

  # Функции-проверки полноты `reservation/1` (`Core.Es.Check`): на каждое событие кодека тело зовёт
  # `reservation/1` каждого модуля ключа.
  @doc false
  @spec checks([declaration()], module(), pos_integer()) :: [Macro.t()]

  def checks([], event_codec, line) when is_atom(event_codec) and is_integer(line), do: []

  def checks([_ | _] = declarations, event_codec, line) when is_atom(event_codec) and is_integer(line) do
    for event <- Enum.sort(event_codec.__es_mods__()) do
      args = [quote(do: unquote(Es.Check.event_pattern(event)) = event)]
      body = for %{module: module} <- declarations, do: quote(do: unquote(module).reservation(event))
      Es.Check.define("reservation/1 принимает", event, args, body, line)
    end
  end

  # ---

  defp modules!(keys, label) when is_list(keys) do
    Enum.map(keys, fn key ->
      Helper.Opts.module!([key_reservations: key], :key_reservations, label,
        exports: [__es_key_reservation__: 0, reservation: 1]
      )
    end)
  end

  defp modules!(keys, label) do
    raise CompileError,
      description: "#{label}: key_reservations: ожидается список модулей ключа, получено #{inspect(keys)}"
  end

  defp declaration!(module, event_codec, id, errors, label) do
    declaration = module.__es_key_reservation__()
    family = event_codec.__codec_union__()

    if declaration.event != family do
      raise CompileError,
        description:
          "#{label}: key_reservations: событие #{inspect(declaration.event)} у #{inspect(module)} " <>
            "не равно семейству кодека #{inspect(family)}"
    end

    if declaration.id != id do
      raise CompileError,
        description:
          "#{label}: key_reservations: id: #{inspect(declaration.id)} у #{inspect(module)} " <>
            "не равен id: #{inspect(id)}"
    end

    ensure_code!(errors, declaration, label)
    declaration
  end

  defp ensure_code!(errors, %{module: module, code: code}, label) do
    errors.domain(__MODULE__, code, nil)
  rescue
    FunctionClauseError ->
      reraise CompileError,
              [
                description:
                  "#{label}: errors: отсутствует clause для #{inspect(code)} в #{inspect(errors)} " <>
                    "(code: у #{inspect(module)})"
              ],
              __STACKTRACE__
  end

  defp ensure_unique_scopes!(declarations, label) do
    declarations
    |> Enum.group_by(& &1.scope, & &1.module)
    |> Enum.find(fn {_scope, modules} -> length(modules) > 1 end)
    |> case do
      nil ->
        :ok

      {scope, modules} ->
        raise CompileError,
          description: "#{label}: key_reservations: область #{inspect(scope)} повторяется: #{inspect(modules)}"
    end
  end

  # ===== поиск =====

  @doc false
  @spec find(declaration(), key(), Context.t()) :: struct() | nil

  def find(%{scope: scope, id: id}, key, %Context{}) do
    query = from(r in Schema, where: r.scope == ^scope and r.key == ^parts(key), select: r.aggregate_id)

    case Config.dao().one(query) do
      nil -> nil
      aggregate_id -> Config.codec().load!(id, aggregate_id)
    end
  end

  # ===== запись =====

  # Резервы по событиям пачки — `append` репозитория после записи событий; `taken` строит ошибку
  # отказа из `code:` модуля ключа и detail `%{scope: scope}`.
  @doc false
  @spec append([declaration()], [Es.Event.t()], Context.t(), (atom(), map() -> Error.t())) ::
          :ok | {:error, Error.t()}

  def append(declarations, events, context, taken)

  def append([], events, %Context{}, taken) when is_list(events) and is_function(taken, 2), do: :ok

  def append([_ | _] = declarations, events, %Context{}, taken) when is_list(events) and is_function(taken, 2) do
    steps = for event <- events, declaration <- declarations, do: {declaration, event}

    case write(steps, Config.codec()) do
      :ok -> :ok
      {:taken, declaration} -> {:error, taken.(declaration.code, %{scope: declaration.scope})}
      {:unresolved, declaration, aggregate_id, reason} -> {:error, unresolved(declaration, aggregate_id, reason)}
    end
  end

  # ---

  defp write([], _codec), do: :ok

  defp write([{declaration, event} | steps], codec) do
    aggregate_id = codec.dump(event.aggregate_id)

    case write_step(declaration, event, aggregate_id) do
      :ok -> write(steps, codec)
      :taken -> {:taken, declaration}
      {:unresolved, reason} -> {:unresolved, declaration, aggregate_id, reason}
    end
  end

  defp write_step(%{module: module, scope: scope}, event, aggregate_id) do
    case module.reservation(event) do
      {:reserve, value} -> reserve(scope, parts(module.to_key(value)), aggregate_id, 0)
      :release -> delete(keys_of(scope, aggregate_id))
      :keep -> :ok
    end
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
