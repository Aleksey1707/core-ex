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

  Записанная пачка после commit транзакции будит читателей проекций типа агрегата
  (`Core.Es.Projection.Registry`); дерево проекций не запущено — будить некого.

  Любой отказ — `{:error, mismatch.(detail)}`: ns и код ошибки задаёт вызывающий
  write-репозиторий, detail — `t:mismatch_detail/0`. `expected` — первая версия потока в
  пачке, `actual` — наибольшая версия потока (`nil` у пустого), прочитанная отдельным
  запросом только на пути ошибки.

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
  событий потока одного агрегата по возрастанию версии; `count` — число событий всего потока.
  Условия видимости по `xid` в запросе нет: порядок внутри потока держит версия. Строки грузятся
  фасадом, апкаст действует; первая ошибка загрузки (`:unknown_event_type`, `:invalid_envelope`) —
  `{:error, _}` на всю страницу, событие не пропускается.

  Доступ не проверяется, `:not_found` нет: пустой поток — страница с `count: 0`. Права и
  существование агрегата вызывающий проверяет до чтения (`docs/rules/13-repos.md`,
  «Страница потока»).

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
  """

  import Ecto.Query

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Es.Store.Schema
  alias Core.Helper.AfterCommit
  alias Core.Pagination
  alias Core.Result

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
    at: :utc_datetime
  }

  @typedoc "Глобальная позиция события: `xid` транзакции записи и номер."
  @type position :: {non_neg_integer(), pos_integer()}

  @typedoc "Событие, прочитанное по глобальной позиции: позиция, тип агрегата, тег, id и конверт."
  @type positioned :: %{
          position: position(),
          type: String.t(),
          tag: String.t(),
          event_id: String.t(),
          wire: Es.Event.Codec.wire()
        }

  @typedoc "Detail отказа записи: поток, первая версия потока в пачке и голова потока."
  @type mismatch_detail :: %{
          aggregate_id: String.t(),
          expected: pos_integer(),
          actual: pos_integer() | nil
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
        ) :: :ok | {:error, Error.t()}

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

    case write_chunks(Enum.chunk_every(rows, @chunk_size), type, continuous?) do
      :ok -> AfterCommit.register(fn -> Es.Projection.Registry.wake(type) end)
      {:refused, aggregate_id} -> {:error, mismatch.(mismatch_detail(type, aggregate_id, rows))}
    end
  end

  # ---

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
      at: fields.at
    }
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
        at: r.at
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
      actual: head_version(type, aggregate_id)
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
        ) :: {:ok, Pagination.Result.t(Es.Event.t())} | {:error, Error.t()}

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

    with {:ok, events} <- Result.traverse(rows, &load(&1, event_codec, codec)) do
      {:ok, Pagination.Result.new(events, Config.dao().aggregate(scope, :count))}
    end
  end

  # ---

  defp stream_scope(type, db_id),
    do: from(e in Schema, where: e.aggregate_type == ^type and e.aggregate_id == ^db_id)

  defp load(row, event_codec, codec),
    do: codec.load(event_codec.__codec_union__(), Schema.to_wire(row))

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
        at: type(e.at, :utc_datetime)
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
      wire: Schema.to_wire(struct(Schema, row))
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
end
