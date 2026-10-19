defmodule Core.Es.Store do
  @moduledoc """
  Хранилище событий — таблица `es_events` (`Core.Es.Migration`): одна на приложение и общая
  для event-sourced и state-stored агрегатов.

  Поток событий — тип агрегата (`type:` кодека событий) и `aggregate_id`. Глобальная позиция
  события — пара `(xid, number)` (`docs/adr/0008-shared-event-table-xid8-position.md`).
  Репозиторий и фасад кодека — `Core.Config.dao/0` и `Core.Config.codec/0`.

  ## Запись

  `append/5` пишет пачку событий нескольких потоков одного типа агрегата в транзакции `DAO`
  вызывающего: чанками по 500 событий, каждый чанк — один `insert_all` из `VALUES` с
  `on_conflict: :nothing` и сверкой числа строк. Пачка отвергается, если хоть одно событие не
  прошло проверку:

  - версия в потоке занята — конкурентная запись (unique ключа потока);
  - в потоке есть событие транзакции с `xid` больше текущей — страж порядка: иначе выдача по
    глобальной позиции переставила бы версии потока. Отказ стража бывает ложным — транзакция
    получила xid раньше, чем закоммитился конкурент по тому же потоку; снимается повтором;
  - с `continuous?: true` первая версия потока в пачке не равна наибольшей версии потока + 1
    (у пустого потока — не 1).

  Страж и непрерывность видят только закоммиченные события. Без `continuous?:` порядок версий
  по позиции держится, пока вызывающий выводит версию из закоммиченного состояния агрегата.

  ПДн-значения пачки (маркеры `Core.Es.Personal.Marker` в дампе) шифруются до вставки одним
  вызовом `seal` хранилища ключей и ложатся в строку как `{"$pd": base64}`; адрес — `event_id` и
  wire-ключ поля. Отказ `seal` (`:subject_destroyed`, сбой хранилища) — `{:error, _}` как есть,
  без `mismatch`. Маркер уничтоженного значения — `ArgumentError` с полем и `event_id`.

  Записанная пачка после commit транзакции будит читателей проекций типа агрегата
  (`Core.Es.Projection.Registry`); дерево проекций не запущено — будить некого.

  Любой отказ — `{:error, mismatch.(detail)}`: ns и код ошибки задаёт вызывающий
  write-репозиторий, detail — `t:mismatch_detail/0`. `expected` — первая версия потока в
  пачке, `actual` — наибольшая версия потока (`nil` у пустого), прочитанная отдельным
  запросом только на пути ошибки.

  `source: :storage` ставится здесь и только здесь: это отказ хранилища, а не сверка ожидаемой
  версии. Он не означает, что вызывающий видел устаревшее состояние, — голова потока бывает ровно
  там, где он её видел, — и снимается повтором команды новой транзакцией (`Core.Es.Transact`).

  Отказ не переводит транзакцию в aborted, она пригодна для дальнейших запросов. Но события,
  прошедшие проверки, к этому моменту уже записаны — транзакцию откатывает вызывающий
  (`Core.Helper.Transact.run/3` по `{:error, _}`).

  Ошибки программиста — исключения: событие не из `tags:` кодека — `FunctionClauseError`;
  версии потока в пачке не по возрастанию, а с `continuous?: true` — не подряд, —
  `ArgumentError`.

  ## Страница потока

  `read_stream/5` — реализация `page_stream/4`, которую генерируют репозитории агрегатов
  (`use Core.Es.Aggregate.Repo.Pg`, `use Core.Repo.Pg.StateStored`) с кодеком агрегата и закрытым
  struct его ID: потребитель читает страницу у репозитория. Отдаёт `Core.Pagination.Result` из
  событий потока одного агрегата по возрастанию версии; `total` — число событий всего потока.
  Условия видимости по `xid` в запросе нет: порядок внутри потока держит версия. Строки грузятся
  фасадом, апкаст действует; первая ошибка загрузки (`:unknown_event_type`, `:invalid_envelope`) —
  `{:error, _}` на всю страницу, событие не пропускается.

  Доступ не проверяется, `:not_found` нет: пустой поток — страница с `total: 0`. Права
  вызывающий проверяет до чтения, существование агрегата — авторитетным для этого агрегата
  источником (`docs/rules/app/13-repos.md`, «Страница потока»).

  ## Чтение по глобальной позиции

  Пачка проекции (`Core.Es.Projection`) читает события типов агрегатов после позиции в порядке
  `(xid, number)`. Видны события транзакций с `xid` ниже `pg_snapshot_xmin` текущего снимка —
  старше самой старой активной пишущей транзакции кластера — и события своей транзакции: в
  sandbox теста это записанное самим тестом, а у пачки на проде своих событий нет.

  С той же видимостью берётся последняя позиция событий типов агрегатов — цель пересборки
  проекции.

  Позиция последнего события потока — цель ожидания проекции (`await/3` модуля проекции) —
  берётся без условия видимости: ожидание идёт после commit, и событие, которое пачка ещё не
  видит, чекпоинт догонит позже.

  ## Загрузка пачки

  Прочитанные строки в события переводит один пакетный шаг — на всех путях чтения: свёртка и хвост
  со снапшотом репозитория event-sourced агрегата, страница потока, пачка проекции,
  `Core.Es.Store.Test.events!/2` и сообщение брокера (`Core.Es.Event.Message.load/2`). Шаг
  принимает пачку строк целиком и проходит её стадиями: все строки → конверты, все `{"$pd": …}`
  пачки → один вызов `open` хранилища ключей, затем каждый конверт → апкаст и загрузка фасадом.
  Открытое значение встаёт на место `$pd` wire-значением поля, уничтоженный ключ — `{"$pd": null}`;
  строку `:skip` шаг не расшифровывает и не грузит.

  Исходы расшифровки: сбой хранилища — `{:error, _}` на всю пачку; значение не открылось —
  `:unreadable_personal_value` (`ns: :es`, `detail` — `event_id` и wire-ключ) у строки.
  Исключение апкаста или загрузки на строке с расшифрованным `$pd` заменяется ошибкой строки
  `:upcast_raised` (`ns: :es`, `:app`): в `detail` — `event_id`, модуль исключения, модуль
  верхнего кадра и стек без аргументов кадров; строки без `$pd` падают как раньше.

  `load_wires/2` — конверты с семейством событий у каждого, исход по конверту (сообщение брокера);
  `load_batch/2` — строки с кодеком событий у каждой, исход по строке (пачка проекции);
  `load_rows/3` — строки одного кодека, первая ошибка на всю пачку; `load_fold_rows/4` — свёртка:
  сбой хранилища — `{:error, _}`, ошибка строки — `Core.Exc`, шифротексты снапшотов идут в тот же
  вызов `open`; `load_rows!/3` — любая ошибка как `Core.Exc`.
  """

  import Ecto.Query

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Es.Personal
  alias Core.Es.Store.Schema
  alias Core.Helper.AfterCommit
  alias Core.Pagination
  alias Core.Result

  require Error

  @chunk_size 500

  # Колонки `VALUES` чанка: строка `es_events` без типа агрегата (он один на пачку и уходит
  # одним параметром), порядок в пачке и первая версия потока в чанке.
  @row_types %{
    ord: :integer,
    aggregate_id: :binary_id,
    aggregate_version: :integer,
    first_version: :integer,
    event_id: :binary_id,
    tag: :string,
    payload: Schema.Payload,
    by_id: :binary_id,
    at: :utc_datetime,
    operation_id: :binary_id,
    session_id: :binary_id,
    basis_id: :binary_id
  }

  @typedoc "Глобальная позиция события: `xid` транзакции записи и номер."
  @type position :: {non_neg_integer(), pos_integer()}

  @typedoc "Событие, прочитанное по глобальной позиции: позиция, тип агрегата, тег, id и строка `es_events`."
  @type positioned :: %{
          position: position(),
          type: String.t(),
          tag: String.t(),
          event_id: String.t(),
          stored: Schema.t()
        }

  @typedoc """
  Строка пачки к загрузке (`load_batch/2`): кодек событий её потока и строка; `:skip` — строка не
  грузится.
  """
  @type entry :: {module(), Schema.t()} | :skip

  @typedoc "Исход строки пачки: событие, ошибка загрузки или пропуск."
  @type loaded :: Result.t(Es.Event.t()) | :skip

  @typedoc """
  Источник отказа `:version_mismatch`: `:expected` — сверка ожидаемой версии, вызывающий назвал
  версию, а действительная другая; `:storage` — отказ хранилища, `append/5` не принял пачку.
  Повтор команды решается по нему (`Core.Es.Transact`).
  """
  @type mismatch_source :: :expected | :storage

  @typedoc """
  Detail отказа `:version_mismatch`: поток, ожидаемая версия (у `append/5` — первая версия потока
  в пачке), голова потока и источник отказа.
  """
  @type mismatch_detail :: %{
          aggregate_id: String.t(),
          expected: pos_integer(),
          actual: pos_integer() | nil,
          source: mismatch_source()
        }

  # ===== запись =====

  @doc """
  Записать события потоков одного типа агрегата — `type:` кодека `event_codec`.

  `mismatch` строит ошибку отказа из `t:mismatch_detail/0`. Опция `continuous?:` —
  непрерывность потока, по умолчанию `false`. Проверки и исходы — в `@moduledoc`.
  """
  @spec append(
          module(),
          [Es.Event.t()],
          Context.t(),
          (mismatch_detail() -> Error.t()),
          keyword()
        ) :: Result.unit()

  def append(event_codec, events, context, mismatch, opts \\ [])

  def append(event_codec, [], %Context{}, mismatch, opts)
      when is_atom(event_codec) and is_function(mismatch, 1) and is_list(opts),
      do: :ok

  def append(event_codec, [_ | _] = events, %Context{}, mismatch, opts)
      when is_atom(event_codec) and is_function(mismatch, 1) and is_list(opts) do
    continuous? = Keyword.fetch!(Keyword.validate!(opts, continuous?: false), :continuous?)
    type = event_codec.__es_type__()
    rows = to_rows(events, event_codec)
    ensure_ordered!(rows, continuous?)

    with {:ok, rows} <- seal_rows(rows), do: write(rows, type, continuous?, mismatch)
  end

  # ---

  defp write(rows, type, continuous?, mismatch) do
    case write_chunks(Enum.chunk_every(rows, @chunk_size), type, continuous?) do
      :ok -> AfterCommit.register(fn -> Es.Projection.Registry.wake(type) end)
      {:refused, aggregate_id} -> {:error, mismatch.(mismatch_detail(type, aggregate_id, rows))}
    end
  end

  defp to_rows(events, event_codec) do
    codec = Config.codec()

    events
    |> Enum.with_index()
    |> Enum.map(fn {event, ord} -> to_row(event, ord, event_codec, codec) end)
  end

  # `type/1` кодека событий — и тег, и проверка, что событие из его `tags:`.
  defp to_row(event, ord, event_codec, codec) do
    tag = event_codec.type(event)
    fields = Es.Event.Codec.to_fields(codec.dump(event))

    %{
      ord: ord,
      aggregate_id: fields.aggregate_id,
      aggregate_version: fields.aggregate_version,
      event_id: fields.id,
      tag: tag,
      payload: fields.payload,
      by_id: fields.by,
      at: fields.at,
      operation_id: fields.operation_id,
      session_id: fields.session_id,
      basis_id: fields.basis_id
    }
  end

  # Маркеры ПДн-значений всех строк пачки — одним вызовом `seal`, в транзакции записи.
  defp seal_rows(rows) do
    with {:ok, payloads} <- Personal.Wire.seal_payloads(Enum.map(rows, &{&1.event_id, &1.payload})),
         do: {:ok, Enum.zip_with(rows, payloads, &%{&1 | payload: &2})}
  end

  defp ensure_ordered!(rows, continuous?) do
    _last_versions =
      Enum.reduce(rows, %{}, fn %{aggregate_id: id, aggregate_version: version}, last_versions ->
        case Map.fetch(last_versions, id) do
          {:ok, last} -> ensure_next!(id, last, version, continuous?)
          :error -> :ok
        end

        Map.put(last_versions, id, version)
      end)

    :ok
  end

  defp ensure_next!(_id, last, version, true) when version == last + 1, do: :ok

  defp ensure_next!(_id, last, version, false) when version > last, do: :ok

  defp ensure_next!(id, last, version, true) do
    raise ArgumentError, "Es.Store: версии потока #{id} в пачке не подряд: #{last} → #{version}"
  end

  defp ensure_next!(id, last, version, false) do
    raise ArgumentError,
          "Es.Store: версии потока #{id} в пачке не по возрастанию: #{last} → #{version}"
  end

  defp write_chunks([], _type, _continuous?), do: :ok

  defp write_chunks([chunk | rest], type, continuous?) do
    case write_chunk(chunk, type, continuous?) do
      :ok -> write_chunks(rest, type, continuous?)
      {:refused, _aggregate_id} = refused -> refused
    end
  end

  # Все проверки чанка — условия того же `INSERT … SELECT`: отказ не поднимает исключение
  # Postgres и не переводит транзакцию в aborted. `returning` нужен пути отказа — найти поток,
  # события которого не записаны.
  defp write_chunk(chunk, type, continuous?) do
    rows = put_first_versions(chunk)
    expected = length(rows)

    case Config.dao().insert_all(Schema, chunk_query(rows, type, continuous?),
           on_conflict: :nothing,
           returning: [:aggregate_id, :aggregate_version]
         ) do
      {^expected, _written} -> :ok
      {_count, written} -> {:refused, refused_aggregate_id(rows, written)}
    end
  end

  # Непрерывность сверяется по первой версии потока в чанке: предыдущие чанки пачки уже
  # записаны этой транзакцией и видны ей головой потока.
  defp put_first_versions(chunk) do
    first_versions = first_versions(chunk)

    Enum.map(chunk, &Map.put(&1, :first_version, Map.fetch!(first_versions, &1.aggregate_id)))
  end

  # Порядок выборки задаёт номер из identity: события пачки получают его в порядке записи.
  defp chunk_query(rows, type, continuous?) do
    later = where(stream(type), [e], e.xid > fragment("pg_current_xact_id()"))

    from(r in values(rows, @row_types),
      as: :row,
      where: not exists(later),
      order_by: r.ord,
      select: %{
        aggregate_type: type(^type, :string),
        aggregate_id: r.aggregate_id,
        aggregate_version: r.aggregate_version,
        event_id: r.event_id,
        tag: r.tag,
        payload: r.payload,
        by_id: r.by_id,
        at: r.at,
        operation_id: r.operation_id,
        session_id: r.session_id,
        basis_id: r.basis_id
      }
    )
    |> continuity(type, continuous?)
  end

  defp continuity(query, _type, false), do: query

  # Первая версия потока в чанке — наибольшая версия + 1: версий не ниже первой в потоке нет,
  # а предыдущая есть либо первая — 1.
  defp continuity(query, type, true) do
    taken = where(stream(type), [e], e.aggregate_version >= parent_as(:row).first_version)
    previous = where(stream(type), [e], e.aggregate_version == parent_as(:row).first_version - 1)

    from(r in query,
      where: not exists(taken),
      where: r.first_version == 1 or exists(previous)
    )
  end

  # События потока строки чанка. Схемы здесь нет: `xid` в неё не входит.
  defp stream(type) do
    from(e in "es_events",
      where: e.aggregate_type == ^type and e.aggregate_id == parent_as(:row).aggregate_id,
      select: 1
    )
  end

  defp refused_aggregate_id(rows, written) do
    written = MapSet.new(written, &{&1.aggregate_id, &1.aggregate_version})

    %{aggregate_id: aggregate_id} =
      Enum.find(rows, &(not MapSet.member?(written, {&1.aggregate_id, &1.aggregate_version})))

    aggregate_id
  end

  defp mismatch_detail(type, aggregate_id, rows) do
    %{
      aggregate_id: aggregate_id,
      expected: Map.fetch!(first_versions(rows), aggregate_id),
      actual: head_version(type, aggregate_id),
      source: :storage
    }
  end

  defp head_version(type, aggregate_id) do
    from(e in Schema,
      where: e.aggregate_type == ^type and e.aggregate_id == ^aggregate_id,
      select: max(e.aggregate_version)
    )
    |> Config.dao().one()
  end

  defp first_versions(rows),
    do: Enum.reduce(rows, %{}, &Map.put_new(&2, &1.aggregate_id, &1.aggregate_version))

  # ===== страница потока =====

  @doc false
  @spec read_stream(
          module(),
          struct(),
          Pagination.Limit.t(),
          Pagination.Offset.t(),
          Context.t()
        ) :: Result.t(Pagination.Result.t(Es.Event.t()))

  def read_stream(
        event_codec,
        %_{} = aggregate_id,
        %Pagination.Limit{} = limit,
        %Pagination.Offset{} = offset,
        %Context{}
      )
      when is_atom(event_codec) do
    codec = Config.codec()
    scope = stream_scope(event_codec.__es_type__(), codec.dump(aggregate_id))

    rows =
      from(e in scope,
        order_by: [asc: e.aggregate_version],
        limit: ^Pagination.Limit.value(limit),
        offset: ^Pagination.Offset.value(offset)
      )
      |> Config.dao().all()

    with {:ok, events} <- load_rows(rows, event_codec, codec) do
      {:ok, Pagination.Result.new(events, Config.dao().aggregate(scope, :count))}
    end
  end

  # ---

  defp stream_scope(type, db_id),
    do: from(e in Schema, where: e.aggregate_type == ^type and e.aggregate_id == ^db_id)

  # ===== чтение по позиции =====

  @doc false
  @spec list_after(Ecto.Repo.t(), [String.t()], position() | nil, pos_integer()) :: [positioned()]

  def list_after(dao, types, position, limit)
      when is_atom(dao) and is_list(types) and is_integer(limit) and limit > 0 do
    from(e in visible(types),
      order_by: [asc: e.xid, asc: e.number],
      limit: ^limit,
      select: %{
        xid: e.xid,
        number: e.number,
        aggregate_type: e.aggregate_type,
        aggregate_id: type(e.aggregate_id, :binary_id),
        aggregate_version: e.aggregate_version,
        event_id: type(e.event_id, :binary_id),
        tag: e.tag,
        payload: e.payload,
        by_id: type(e.by_id, :binary_id),
        at: type(e.at, :utc_datetime),
        operation_id: type(e.operation_id, :binary_id),
        session_id: type(e.session_id, :binary_id),
        basis_id: type(e.basis_id, :binary_id)
      }
    )
    |> after_position(position)
    |> dao.all()
    |> Enum.map(&positioned/1)
  end

  @doc false
  @spec last_position(Ecto.Repo.t(), [String.t()]) :: position() | nil

  def last_position(dao, types) when is_atom(dao) and is_list(types) do
    from(e in visible(types),
      order_by: [desc: e.xid, desc: e.number],
      limit: 1,
      select: {e.xid, e.number}
    )
    |> dao.one()
  end

  @doc false
  @spec last_stream_position(Ecto.Repo.t(), String.t(), String.t()) :: position() | nil

  def last_stream_position(dao, type, aggregate_id)
      when is_atom(dao) and is_binary(type) and is_binary(aggregate_id) do
    from(e in "es_events",
      where: e.aggregate_type == ^type and e.aggregate_id == type(^aggregate_id, :binary_id),
      order_by: [desc: e.aggregate_version],
      limit: 1,
      select: {e.xid, e.number}
    )
    |> dao.one()
  end

  @doc false
  @spec stream_position(Ecto.Repo.t(), String.t(), String.t(), pos_integer()) :: position() | nil

  def stream_position(dao, type, aggregate_id, version)
      when is_atom(dao) and is_binary(type) and is_binary(aggregate_id) and is_integer(version) do
    from(e in "es_events",
      where:
        e.aggregate_type == ^type and e.aggregate_id == type(^aggregate_id, :binary_id) and
          e.aggregate_version == ^version,
      select: {e.xid, e.number}
    )
    |> dao.one()
  end

  # Условия видимости пачки нет: закоммиченное событие, которое пачка ждёт за долгой транзакцией,
  # тоже не обработано.
  @doc false
  @spec oldest_at_after(Ecto.Repo.t(), [String.t()], position() | nil) :: DateTime.t() | nil

  def oldest_at_after(dao, types, position) when is_atom(dao) and is_list(types) do
    types
    |> Enum.map(&first_at_after(dao, &1, position))
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> nil end)
  end

  # ---

  defp after_position(query, nil), do: query

  defp after_position(query, {xid, number}),
    do: where(query, [e], fragment("(?, ?) > (?::xid8, ?)", e.xid, e.number, ^xid, ^number))

  # Колонок позиции в схеме нет: строка собирается в неё без них.
  defp positioned(row) do
    %{
      position: {row.xid, row.number},
      type: row.aggregate_type,
      tag: row.tag,
      event_id: row.event_id,
      stored: struct(Schema, row)
    }
  end

  defp visible(types) do
    from(e in "es_events",
      where: e.aggregate_type in type(^types, {:array, :string}),
      where:
        fragment(
          "? < pg_snapshot_xmin(pg_current_snapshot()) OR ? = pg_current_xact_id_if_assigned()",
          e.xid,
          e.xid
        )
    )
  end

  defp first_at_after(dao, type, position) do
    from(e in "es_events",
      where: e.aggregate_type == ^type,
      order_by: [asc: e.xid, asc: e.number],
      limit: 1,
      select: type(e.at, :utc_datetime)
    )
    |> after_position(position)
    |> dao.one()
  end

  # ===== загрузка пачки =====

  @doc false
  @spec load_rows([Schema.t()], module(), module()) :: Result.t([Es.Event.t()])

  def load_rows(rows, event_codec, codec) when is_list(rows) and is_atom(event_codec) and is_atom(codec) do
    with {:ok, loaded} <- load_batch(Enum.map(rows, &{event_codec, &1}), codec),
         do: Result.traverse(loaded, & &1)
  end

  @doc false
  @spec load_fold_rows([Schema.t()], module(), module(), [{binary(), binary()}]) ::
          Result.t({[Es.Event.t()], [Personal.KeyStore.opened()]})

  def load_fold_rows(rows, event_codec, codec, sealed)
      when is_list(rows) and is_atom(event_codec) and is_atom(codec) and is_list(sealed) do
    with {:ok, {loaded, opened}} <- load_entries(Enum.map(rows, &to_wire({event_codec, &1})), codec, sealed),
         do: {:ok, {Enum.map(loaded, &Result.unwrap!/1), opened}}
  end

  @doc false
  @spec load_rows!([Schema.t()], module(), module()) :: [Es.Event.t()]

  def load_rows!(rows, event_codec, codec) when is_list(rows) and is_atom(event_codec) and is_atom(codec),
    do: Result.unwrap!(load_rows(rows, event_codec, codec))

  @doc false
  @spec load_batch([entry()], module()) :: Result.t([loaded()])

  def load_batch(entries, codec) when is_list(entries) and is_atom(codec),
    do: load_wires(Enum.map(entries, &to_wire/1), codec)

  @doc false
  @spec load_wires([{module(), Es.Event.Codec.wire()} | :skip], module()) :: Result.t([loaded()])

  def load_wires(entries, codec) when is_list(entries) and is_atom(codec) do
    with {:ok, {loaded, []}} <- load_entries(entries, codec, []), do: {:ok, loaded}
  end

  # ---

  defp load_entries(entries, codec, sealed) do
    with {:ok, {opened, opened_sealed}} <- Personal.Wire.open_wires(Enum.map(entries, &wire/1), sealed),
         do: {:ok, {Enum.zip_with(entries, opened, &load_wire(&1, &2, codec)), opened_sealed}}
  end

  defp to_wire(:skip), do: :skip

  defp to_wire({event_codec, %Schema{} = row}) when is_atom(event_codec),
    do: {event_codec.__codec_union__(), Schema.to_wire(row)}

  defp wire(:skip), do: :skip
  defp wire({_family, wire}), do: wire

  defp load_wire(:skip, :skip, _codec), do: :skip
  defp load_wire(_entry, {:unreadable, event_id, field}, _codec), do: {:error, unreadable(event_id, field)}
  defp load_wire({family, _wire}, {:ok, {wire, false}}, codec), do: codec.load(family, wire)

  defp load_wire({family, _wire}, {:ok, {wire, true}}, codec) do
    codec.load(family, wire)
  rescue
    exception -> {:error, upcast_raised(wire, exception, __STACKTRACE__)}
  end

  defp unreadable(event_id, field) do
    Error.domain(__MODULE__,
      code: :unreadable_personal_value,
      ns: :es,
      message: "ПДн-значение события не читается",
      detail: %{event_id: event_id, field: field}
    )
  end

  # Строка с расшифрованным ПДн-значением: текст исключения и аргументы кадров несли бы открытые
  # строки wire-карты — остаются только модуль исключения, место и стек без аргументов.
  defp upcast_raised(wire, %exception{}, stacktrace) do
    Error.app(__MODULE__,
      code: :upcast_raised,
      ns: :es,
      message: "Исключение апкаста или загрузки события с ПДн-значением",
      detail: %{
        event_id: Es.Event.Codec.to_fields(wire).id,
        exception: exception,
        module: raised_in(stacktrace),
        stacktrace: Enum.map(stacktrace, &without_args/1)
      }
    )
  end

  defp raised_in([{module, _fun, _arity, _location} | _stacktrace]), do: module
  defp raised_in(_stacktrace), do: nil

  defp without_args({module, fun, args, location}) when is_list(args), do: {module, fun, length(args), location}
  defp without_args(frame), do: frame
end
