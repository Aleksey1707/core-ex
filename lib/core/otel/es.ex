defmodule Core.Otel.Es do
  @moduledoc """
  Span'ы event sourcing: словарь атрибутов `core.es.*` и операции, которые их ставят.

  | Функция | Span | Родитель |
  |---|---|---|
  | `project/3` | `project <имя проекции>`, `:internal` | нет — корневой |
  | `await/4` | `await <имя проекции>`, `:internal` | span вызывающего |
  | `execute/4` | `execute <тип агрегата>`, `:internal` | span вызывающего |

  `project/3` открывает span только пачке проекции с работой — старт с начала истории или
  события после чекпоинта; холостая пачка span'а не получает. Пачка несёт события разных команд,
  поэтому родителя у span'а нет, а связь с командой — `core.es.event.id` события, на котором
  пачка отказала. Контекст трейса в хранилище событий не хранится.

  Атрибуты пачки ставятся внутри `project/3`: `batch/3` — в начале, `checkpoint/1` — после
  сдвига чекпоинта, `failed/2` — на отказе. Позиция в атрибуте — `"<xid>/<номер>"`.

  `await/4` — ожидание проекции после записи (`Core.Es.Projection.await/4`) в процессе
  вызывающего: часть его запроса, поэтому span дочерний. Ошибка ожидания — `record_error/1`.

  `execute/4` — команда процесса агрегата (`Core.Es.Aggregate.Process`) на call site
  `Agg.Process.execute` в процессе вызывающего; режим и число повторов ставит `executed/2`, выход
  команды из очереди процесса на id — `dequeued/0`.
  Прикладная ошибка — `record_error/1`; доменный отказ, в том числе `:version_mismatch` после
  повторов, — исход команды, а не сбой: статус span'а не меняется.
  """

  alias Core.Error
  alias Core.Es
  alias Core.Otel

  @attr_projection_name "core.es.projection.name"
  @attr_projection_version "core.es.projection.version"
  @attr_projection_reset "core.es.projection.reset"
  @attr_batch_event_count "core.es.batch.event_count"
  @attr_checkpoint_from "core.es.checkpoint.from"
  @attr_checkpoint_to "core.es.checkpoint.to"
  @attr_event_id "core.es.event.id"
  @attr_aggregate_type "core.es.aggregate.type"
  @attr_aggregate_id "core.es.aggregate.id"
  @attr_command "core.es.command"
  @attr_execute_mode "core.es.execute.mode"
  @attr_retries "core.es.retries"

  # ===== пачка проекции =====

  @doc "Выполнить `fun` — пачку проекции — в корневом span'е `project <имя проекции>`."
  @spec project(String.t(), pos_integer(), (-> result)) :: result when result: var

  def project(projection_name, version, fun)
      when is_binary(projection_name) and is_integer(version) and is_function(fun, 0) do
    attributes = %{
      @attr_projection_name => projection_name,
      @attr_projection_version => version
    }

    Otel.root_span("project #{projection_name}", [attributes: attributes], fun)
  end

  @doc """
  Отметить пачку: старт с начала истории, число прочитанных событий и чекпоинт до пачки.

  `from` `nil` — чекпоинт в начале истории, атрибут не ставится.
  """
  @spec batch(boolean(), non_neg_integer(), Es.Store.position() | nil) :: :ok

  def batch(reset?, event_count, from)
      when is_boolean(reset?) and is_integer(event_count) and event_count >= 0 do
    %{@attr_projection_reset => reset?, @attr_batch_event_count => event_count}
    |> put_position(@attr_checkpoint_from, from)
    |> Otel.set_attributes()
  end

  @doc "Отметить чекпоинт после пачки; `nil` — начало истории, атрибут не ставится."
  @spec checkpoint(Es.Store.position() | nil) :: :ok

  def checkpoint(to) do
    %{}
    |> put_position(@attr_checkpoint_to, to)
    |> Otel.set_attributes()
  end

  @doc "Отметить отказ пачки: ошибку и событие, на котором он случился (`nil` — не на событии)."
  @spec failed(Error.t(), String.t() | nil) :: :ok

  def failed(%Error{} = error, event_id) when is_binary(event_id) or is_nil(event_id) do
    :ok =
      %{}
      |> put_event_id(event_id)
      |> Otel.set_attributes()

    Otel.record_error(error)
  end

  # ---

  defp put_position(attributes, _key, nil), do: attributes

  defp put_position(attributes, key, {xid, number}),
    do: Map.put(attributes, key, "#{xid}/#{number}")

  defp put_event_id(attributes, nil), do: attributes
  defp put_event_id(attributes, event_id), do: Map.put(attributes, @attr_event_id, event_id)

  # ===== ожидание проекции =====

  @doc """
  Выполнить `fun` — ожидание проекции после записи — в span'е `await <имя проекции>` внутри
  трейса вызывающего; `{:error, _}` результата отмечается `Core.Otel.record_error/1`.
  """
  @spec await(String.t(), String.t(), String.t(), (-> :ok | {:error, Error.t()})) ::
          :ok | {:error, Error.t()}

  def await(projection_name, type, aggregate_id, fun)
      when is_binary(projection_name) and is_binary(type) and is_binary(aggregate_id) and
             is_function(fun, 0) do
    attributes = %{
      @attr_projection_name => projection_name,
      @attr_aggregate_type => type,
      @attr_aggregate_id => aggregate_id
    }

    Otel.span("await #{projection_name}", [attributes: attributes], fn -> recorded(fun.()) end)
  end

  # ---

  defp recorded(:ok), do: :ok

  defp recorded({:error, %Error{} = error} = result) do
    :ok = Otel.record_error(error)
    result
  end

  # ===== команда агрегата =====

  @doc """
  Выполнить `fun` — команду `command` агрегата — в span'е `execute <тип>` внутри трейса
  вызывающего; прикладная `{:error, _}` результата отмечается `Core.Otel.record_error/1`.
  """
  @spec execute(String.t(), String.t(), module(), (-> :ok | {:error, Error.t()})) ::
          :ok | {:error, Error.t()}

  def execute(type, aggregate_id, command, fun)
      when is_binary(type) and is_binary(aggregate_id) and is_atom(command) and
             is_function(fun, 0) do
    attributes = %{
      @attr_aggregate_type => type,
      @attr_aggregate_id => aggregate_id,
      @attr_command => inspect(command)
    }

    Otel.span("execute #{type}", [attributes: attributes], fn -> app_recorded(fun.()) end)
  end

  @doc "Отметить исполнение команды: режим и число повторов после конфликта версии."
  @spec executed(:inline | :process, non_neg_integer()) :: :ok

  def executed(mode, retries)
      when mode in ~w(inline process)a and is_integer(retries) and retries >= 0 do
    Otel.set_attributes(%{
      @attr_execute_mode => Atom.to_string(mode),
      @attr_retries => retries
    })
  end

  @doc """
  Отметить выход команды из очереди процесса агрегата на id — span event `dequeued` текущего
  span'а: процесс исполняет команду в OTel-контексте вызывающего.
  """
  @spec dequeued() :: :ok

  def dequeued, do: Otel.add_event("dequeued", %{})

  # ---

  defp app_recorded({:error, %Error{kind: :app} = error} = result) do
    :ok = Otel.record_error(error)
    result
  end

  defp app_recorded(result), do: result
end
