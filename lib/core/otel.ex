defmodule Core.Otel do
  @moduledoc """
  Фасад OpenTelemetry: span'ы, контекст процесса и пропагация через carrier.

  Модуль **предметно нейтрален**: он не знает ни про MQ, ни про outbox, ни про HTTP.
  Атрибуты приходят готовой картой (`attributes:`), их имена — забота вызывающего.
  Словарь semconv для сообщений — `Core.Otel.Messaging`.

  Зависимость — только `opentelemetry_api`: без SDK все вызовы no-op
  (`otel_tracer_noop`), `inject/1` возвращает carrier как есть, а извлечённый
  из carrier родитель всё равно продолжает трейс. SDK, exporter и
  автоинструментирование подключает потребитель (см. README).

  ## Зачем он нужен библиотеке

  Готовые интеграции (`opentelemetry_phoenix`, `opentelemetry_ecto`,
  `opentelemetry_oban`) закрывают HTTP, SQL и джобы, но рвутся на собственном
  асинхронном транспорте Core: запись создаётся в одном процессе, публикуется
  поллером в другом, читается подписчиком в третьем. Контекст OTel живёт
  в process dictionary и ни через строку в БД, ни через `GenServer.call`
  сам не переносится — переносит его этот модуль.

  ## Instrumentation scope

  По умолчанию span приписывается приложению `:core`. Код потребителя,
  вызывающий фасад напрямую, передаёт свой модуль опцией `scope:` — иначе
  его span'ы в бэкенде выглядят как span'ы библиотеки.
  """

  alias Core.Error

  use Core.Options

  @attr_error_type "error.type"
  @attr_error_kind "core.error.kind"

  @typedoc "Носитель контекста трейса: карта строковых заголовков."
  @type carrier :: %{optional(String.t()) => String.t()}

  @typedoc "Атрибуты span'а: имена — semconv или собственные, значения — скаляры."
  @type attributes :: %{optional(String.t()) => :opentelemetry.attribute_value()}

  @typedoc "Контекст span'а — то, на что ссылаются `links:`."
  @type span_ctx :: :opentelemetry.span_ctx()

  @typedoc "Контекст трейса процесса."
  @type ctx :: :otel_ctx.t()

  @span_opts_schema [
    kind: [
      type: {:in, ~w(internal producer consumer client server)a},
      type_doc: "`t::opentelemetry.span_kind/0`",
      default: :internal,
      doc: "Вид span'а."
    ],
    attributes: [type: {:map, :string, :any}, default: %{}, doc: "Атрибуты span'а (`t:attributes/0`)."],
    links: [
      type: {:list, :any},
      type_doc: "список `t:span_ctx/0`",
      default: [],
      doc: "Контексты связанных span'ов; невалидные отбрасываются."
    ],
    scope: [type: :atom, default: __MODULE__, doc: "Модуль, по приложению которого выбирается tracer."]
  ]

  @doc """
  Записать в carrier контекст текущего трейса.

  Поля пропагатора (`traceparent`, `tracestate`, `baggage` — зависит от
  настроек потребителя) сначала снимаются: carrier мог прийти с контекстом
  другого звена, и остаток старого `tracestate` рядом с новым `traceparent`
  дал бы подписчику несогласованную пару.

  Вне span'а (в том числе когда SDK не подключён) carrier возвращается как есть.
  """
  @spec inject(carrier()) :: carrier()

  def inject(carrier) when is_map(carrier) do
    injector = :opentelemetry.get_text_map_injector()
    fields = :otel_propagator_text_map.fields(injector)

    carrier
    |> Map.drop(fields)
    |> Map.merge(Map.new(:otel_propagator_text_map.inject([])))
  end

  @doc "Выполнить `fun` в span'е внутри текущего контекста."
  @opts_schema @span_opts_schema
  @spec span(String.t(), (-> result), keyword()) :: result when result: var

  def span(name, fun, opts \\ []) when is_binary(name) and is_function(fun, 0) and is_list(opts) do
    :otel_tracer.with_span(tracer(opts), name, start_opts(opts), fn _span -> fun.() end)
  end

  @doc """
  Выполнить `fun` в корневом span'е — без родителя, даже внутри span'а процесса.

  Нужен работе, которую не вызвал ни один трейс процесса: пачка несёт события разных команд.
  Прежний контекст возвращается процессу по выходе. Опции — как у `span/3`, проверяет она.
  """
  @spec root_span(String.t(), (-> result), keyword()) :: result when result: var

  def root_span(name, fun, opts \\ []) when is_binary(name) and is_function(fun, 0) and is_list(opts),
    do: with_ctx(:otel_ctx.new(), fn -> span(name, fun, opts) end)

  @doc """
  Выполнить `fun` в span'е, родитель которого извлечён из carrier.

  Прежний контекст процесса восстанавливается в `after`: процесс, обрабатывающий
  поток чужих сообщений (подписчик), не имеет права унести контекст одного
  сообщения в обработку следующего.
  """
  @opts_schema @span_opts_schema
  @spec with_span_from(carrier(), String.t(), (-> result), keyword()) :: result
        when result: var

  def with_span_from(carrier, name, fun, opts \\ [])
      when is_map(carrier) and is_binary(name) and is_function(fun, 0) and is_list(opts) do
    previous = :otel_ctx.get_current()
    parent = :otel_propagator_text_map.extract_to(previous, Map.to_list(carrier))

    try do
      :otel_tracer.with_span(parent, tracer(opts), name, start_opts(opts), fn _span -> fun.() end)
    after
      :otel_ctx.attach(previous)
    end
  end

  @doc """
  Контекст текущего span'а или `:undefined`.

  Нужен там, где связь выражается ссылкой, а не вложенностью: контекст
  закрытого span'а передаётся следующему звену опцией `links:`.
  """
  @spec current_span() :: span_ctx() | :undefined

  def current_span, do: :otel_tracer.current_span_ctx()

  @doc "Добавить событие к текущему span'у — момент внутри span'а без своей длительности."
  @spec add_event(String.t(), attributes()) :: :ok

  def add_event(name, attributes) when is_binary(name) and is_map(attributes) do
    _recorded? = :otel_span.add_event(:otel_tracer.current_span_ctx(), name, attributes)
    :ok
  end

  @doc "Добавить атрибуты к текущему span'у — то, что известно не на старте."
  @spec set_attributes(attributes()) :: :ok

  def set_attributes(attributes) when is_map(attributes) do
    _ = :otel_span.set_attributes(current_span(), attributes)
    :ok
  end

  @doc """
  Отметить ошибку на текущем span'е: `error.type` и статус `:error`.

  В сообщение статуса уходит cause-цепочка (`Error.format_chain/1`), а не только
  код: по коду не отличить сбой брокера от отказа обработчика. Отдельным
  атрибутом причина не дублируется.
  """
  @spec record_error(Error.t()) :: :ok

  def record_error(%Error{} = error) do
    span = current_span()

    _ =
      :otel_span.set_attributes(span, %{
        @attr_error_type => "#{error.ns}/#{error.code}",
        @attr_error_kind => Atom.to_string(error.kind)
      })

    _ = :otel_span.set_status(span, :error, Error.format_chain(error))
    :ok
  end

  @doc """
  Отметить исключение на текущем span'е: `error.type` и статус `:error`.

  `error.type` — модуль исключения (`RuntimeError`), у `exit` и `throw` — имя вида. Текст
  исключения и стек в span не уходят: в них бывает аргумент вызова, а span уходит во внешний
  коллектор целиком.
  """
  @spec record_exception(:error | :exit | :throw, term(), Exception.stacktrace()) :: :ok

  def record_exception(kind, reason, stacktrace) when kind in ~w(error exit throw)a,
    do: record_failure(exception_type(kind, reason, stacktrace))

  @doc """
  Отметить сбой без `%Error{}` на текущем span'е: `error.type` и статус `:error` с тем же текстом.

  Нужен исходу, который классифицирует вызывающий (`timeout` внешнего вызова): ошибки как значения у
  него нет, а `error.type` — из закрытого множества словаря.
  """
  @spec record_failure(String.t()) :: :ok

  def record_failure(type) when is_binary(type) do
    span = current_span()

    _ = :otel_span.set_attributes(span, %{@attr_error_type => type})
    _ = :otel_span.set_status(span, :error, type)
    :ok
  end

  @doc "Контекст трейса текущего процесса — для явной передачи в порождённый."
  @spec ctx() :: ctx()

  def ctx, do: :otel_ctx.get_current()

  @doc "Выполнить `fun` в переданном контексте, вернув процессу прежний."
  @spec with_ctx(ctx(), (-> result)) :: result when result: var

  def with_ctx(ctx, fun) when is_function(fun, 0) do
    token = :otel_ctx.attach(ctx)

    try do
      fun.()
    after
      :otel_ctx.detach(token)
    end
  end

  # ---

  defp exception_type(:error, reason, stacktrace) do
    %module{} = Exception.normalize(:error, reason, stacktrace)
    inspect(module)
  end

  defp exception_type(kind, _reason, _stacktrace), do: Atom.to_string(kind)

  defp tracer(opts) do
    :opentelemetry.get_application_tracer(Keyword.fetch!(opts, :scope))
  end

  defp start_opts(opts) do
    %{
      kind: Keyword.fetch!(opts, :kind),
      attributes: Keyword.fetch!(opts, :attributes),
      links: :opentelemetry.links(Keyword.fetch!(opts, :links))
    }
  end
end
