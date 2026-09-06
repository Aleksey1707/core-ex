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

  @typedoc """
  Опции старта span'а.

  - `kind:` — `:internal` (по умолчанию), `:producer`, `:consumer`, `:client`, `:server`
  - `attributes:` — карта атрибутов
  - `links:` — контексты связанных span'ов (невалидные отбрасываются)
  - `scope:` — модуль, по приложению которого выбирается tracer; по умолчанию `Core.Otel`
  """
  @type start_opts :: [
          kind: :opentelemetry.span_kind(),
          attributes: attributes(),
          links: [span_ctx()],
          scope: module()
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
  @spec span(String.t(), start_opts(), (-> result)) :: result when result: var

  def span(name, opts, fun) when is_binary(name) and is_list(opts) and is_function(fun, 0) do
    :otel_tracer.with_span(tracer(opts), name, start_opts(opts), fn _span -> fun.() end)
  end

  @doc """
  Выполнить `fun` в span'е, родитель которого извлечён из carrier.

  Прежний контекст процесса восстанавливается в `after`: процесс, обрабатывающий
  поток чужих сообщений (подписчик), не имеет права унести контекст одного
  сообщения в обработку следующего.
  """
  @spec with_span_from(carrier(), String.t(), start_opts(), (-> result)) :: result
        when result: var

  def with_span_from(carrier, name, opts, fun)
      when is_map(carrier) and is_binary(name) and is_list(opts) and is_function(fun, 0) do
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

  defp tracer(opts) do
    :opentelemetry.get_application_tracer(Keyword.get(opts, :scope, __MODULE__))
  end

  defp start_opts(opts) do
    %{
      kind: Keyword.get(opts, :kind, :internal),
      attributes: Keyword.get(opts, :attributes, %{}),
      links: :opentelemetry.links(Keyword.get(opts, :links, []))
    }
  end
end
