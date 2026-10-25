# `open_api_spex` объявлен в библиотеке `optional: true` (ADR-0064): ратчет спецификаций нужен только
# приложению, которое описывает API через OpenAPI.
if Code.ensure_loaded?(OpenApiSpex) do
  defmodule Core.Web.ApiSpecCase do
    @moduledoc """
    Case-модуль спецификаций OpenAPI приложения: параметры страницы — в query, а не в теле запроса.

        defmodule MyAppWeb.ApiSpecTest do
          use Core.Web.ApiSpecCase,
            otp_app: :my_app,
            async: true
        end

    Один тест-модуль на приложение поверх `ExUnit.Case`. Норма `app/15-web-api.md`, «Поверхности и
    версии» — страница (`limit` / `offset`) в query у любой выборки — держится тестом на все
    спецификации, а не ревью: `Core.Web.Params.page/2` разбирает любую map, и страница, положенная в
    тело, разбирается молча.

    Спецификации — модули `otp_app:` с `@behaviour OpenApiSpex.OpenApi` (`ApiSpec` версии
    поверхности), каждая — результат её `spec/0`. Перечня нет: новая поверхность или версия
    попадает под проверку сама.

    ## Генерируемые тесты

    1. у приложения есть хотя бы одна спецификация: иначе проверка ниже прошла бы на пустом обходе;
    2. ни у одной операции схема тела запроса не объявляет свойства `limit` / `offset`. Схема
       разворачивается по ссылке `#/components/schemas/…`, по модулю схемы и по `allOf`.

    Логика теста — функция `check_*` (`:ok | {:error, detail}`), сам тест — `assert :ok = …`:
    провал печатает спецификацию, операцию и поле.

    ## Opts

    - `otp_app:` — приложение, чьи спецификации проверяются, обязательная; не загружено — провал
      всех тестов модуля
    - `async:` — опция `ExUnit.Case`, необязательная, по умолчанию `true`; явное значение требует
      `Credo.Check.Refactor.PassAsyncInTestCases`

    Все опции — литералы: ключи и значения проверяются при раскрытии `use`.
    """

    alias Core.Helper
    alias Core.Result
    alias OpenApiSpex.MediaType
    alias OpenApiSpex.OpenApi
    alias OpenApiSpex.PathItem
    alias OpenApiSpex.Reference
    alias OpenApiSpex.RequestBody

    @label "Web.ApiSpecCase"
    @required_keys ~w(otp_app)a
    @optional_keys ~w(async)a
    @expression_keys ~w()a
    @page_fields ~w(limit offset)
    @methods ~w(get put post delete options head patch trace)a

    @typedoc "Спецификация приложения: модуль `ApiSpec` и результат его `spec/0`."
    @type spec :: {module(), OpenApi.t()}

    @typedoc "Поля страницы в теле запроса: `{ApiSpec, метод, путь, поле}`."
    @type page_in_body :: %{page_in_body: [{module(), atom(), String.t(), String.t()}]}

    # ===== объявление =====

    @doc "Сгенерировать тесты спецификаций OpenAPI приложения."
    defmacro __using__(opts) do
      opts = Helper.Opts.expand!(opts, __CALLER__, @label)
      Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
      opts = Helper.Opts.literal!(opts, @expression_keys, @label)
      otp_app = Helper.Opts.atom!(opts, :otp_app, @label)
      async = async!(opts)

      quote do
        use ExUnit.Case, async: unquote(async)

        setup_all do
          %{specs: Core.Web.ApiSpecCase.specs!(unquote(otp_app))}
        end

        test "обход находит спецификации", %{specs: specs} do
          assert :ok = Core.Web.ApiSpecCase.check_found(specs)
        end

        test "параметры страницы — в query, а не в теле запроса", %{specs: specs} do
          assert :ok = Core.Web.ApiSpecCase.check_page_in_query(specs)
        end
      end
    end

    # ---

    defp async!(opts) do
      case Keyword.get(opts, :async, true) do
        async when is_boolean(async) ->
          async

        other ->
          Helper.Opts.reject!("#{@label}: async", "ожидается boolean, получено #{inspect(other)}")
      end
    end

    # ===== спецификации приложения =====

    @doc false
    @spec specs!(atom()) :: [spec()]

    def specs!(app) when is_atom(app) do
      case :application.get_key(app, :modules) do
        {:ok, modules} -> for module <- Enum.sort(modules), api_spec?(module), do: {module, module.spec()}
        :undefined -> raise ArgumentError, "#{@label}: приложение #{inspect(app)} не загружено"
      end
    end

    # ---

    defp api_spec?(module) do
      Helper.Module.exports?(module, :spec, 0) and
        OpenApi in Enum.concat(Keyword.get_values(module.module_info(:attributes), :behaviour))
    end

    # ===== проверки =====

    @doc false
    @spec check_found([spec()]) :: Result.unit(:empty)

    def check_found([]), do: {:error, :empty}
    def check_found([_ | _]), do: :ok

    @doc false
    @spec check_page_in_query([spec()]) :: Result.unit(page_in_body())

    def check_page_in_query(specs) when is_list(specs) do
      found =
        for {module, %OpenApi{} = spec} <- specs,
            {path, %PathItem{} = item} <- spec.paths || %{},
            method <- @methods,
            operation = Map.fetch!(item, method),
            operation != nil,
            field <- body_fields(operation.requestBody, spec),
            field in @page_fields,
            do: {module, method, path, field}

      case Enum.sort(found) do
        [] -> :ok
        found -> {:error, %{page_in_body: found}}
      end
    end

    # ---

    defp body_fields(nil, _spec), do: []

    defp body_fields(%Reference{"$ref": "#/components/requestBodies/" <> name}, spec),
      do: body_fields(component(spec, :requestBodies, name), spec)

    defp body_fields(%RequestBody{content: content}, spec) do
      content
      |> Map.values()
      |> Enum.flat_map(fn %MediaType{schema: schema} -> schema_fields(schema, spec, MapSet.new()) end)
      |> Enum.uniq()
    end

    defp schema_fields(nil, _spec, _seen), do: []

    defp schema_fields(%OpenApiSpex.Schema{properties: properties, allOf: all_of}, spec, seen) do
      own = Enum.map(Map.keys(properties || %{}), &to_string/1)
      own ++ Enum.flat_map(all_of || [], &schema_fields(&1, spec, seen))
    end

    defp schema_fields(%Reference{"$ref": "#/components/schemas/" <> name = ref}, spec, seen),
      do: unseen(ref, seen, &schema_fields(component(spec, :schemas, name), spec, &1))

    defp schema_fields(module, spec, seen) when is_atom(module),
      do: unseen(module, seen, &schema_fields(module.schema(), spec, &1))

    defp unseen(key, seen, fun) do
      if MapSet.member?(seen, key), do: [], else: fun.(MapSet.put(seen, key))
    end

    defp component(%OpenApi{components: nil}, _kind, _name), do: nil
    defp component(%OpenApi{components: components}, kind, name), do: Map.get(Map.get(components, kind) || %{}, name)
  end
end
