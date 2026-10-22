defmodule Core.Es.Event.Payload do
  @moduledoc """
  Билдер нагрузки события по полям: struct, позиционный `new`, `@type t` и спека полей
  из одной декларации.

      defmodule Payload do
        use Core.Es.Event.Payload,
          fields: [
            name: [prim: Account.Name],
            note: [prim: Account.Note, optional: true],
            phone: [prim: Account.Phone, subject: :aggregate_id]
          ]
      end

  Спека полей — та же, что у Codec-плагина (`Core.Codec.Field`), без `default:`:
  событие развивается новым тегом и апкастом (ADR-0010, ADR-0020), а не дефолтом —
  `default:` даёт `CompileError`.

  `subject:` — субъект ПДн-значения поля (ADR-0073): `:aggregate_id` или имя поля той же нагрузки
  с `Prim.UUID` / `Prim.Compose` над ним. `CompileError`:

  - персональный Prim (`personal: true`) на поле `prim:` / `list: [prim:]` без `subject:`;
  - субъект — не `Prim.UUID` и не `Prim.Compose` над ним (у `:aggregate_id` проверяет
    `use Core.Es.Event`), поле с `subject:` в роли субъекта;
  - обязательное поле при необязательном поле-субъекте;
  - `subject:` на несуществующее поле или на само себя;
  - wire-ключ на `$` у любого поля: форма `{"$pd": …}` зарезервирована.

  Порождаются:

  - `@enforce_keys` (все поля, кроме `optional: true`) и `defstruct`;
  - `@type t` по видам полей (`optional:` — `| nil`, `subject:` — `| Core.Es.Personal.Destroyed.t()`);
  - `new/N` — поля позиционно в порядке объявления; голова проверяет вид каждого поля, как
    `dump/2` плагина по полям (вариант семейства `union:` — только `is_struct`), так что нагрузка
    не того вида ловится при сборке вызывающего. `%Core.Es.Personal.Destroyed{}` и непустое
    ПДн-значение при `nil` в поле-субъекте голова не пропускает;
  - `Inspect` без полей с `subject:`;
  - `__es_payload_fields__/0` — внутренняя для `Core.Es.Event.Codec`: нормализованные поля спеки
    (`Core.Codec.Field`), форма поля — не контракт.

  Кодирует такую нагрузку `Core.Es.Event.Codec` события: её клаузы он выводит сам. В фасаде
  нагрузка не регистрируется.

  Макрос занимает в модуле нагрузки имя `@es_payload_fields`.
  """

  alias Core.Codec.Field
  alias Core.Helper

  @doc "Объявить нагрузку события по полям (`fields:`)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(opts, ~w(fields)a, [], "Es.Event.Payload")

      @es_payload_fields Core.Codec.Plugin.Fields.check_subjects!(
                           Core.Codec.Field.payload_fields!(__MODULE__, Keyword.fetch!(opts, :fields)),
                           __MODULE__
                         )

      case Keyword.keys(Core.Codec.Field.subjects(@es_payload_fields)) do
        [] -> :ok
        hidden -> @derive {Inspect, except: hidden}
      end

      @enforce_keys for %Core.Codec.Field{name: name, optional?: false} <- @es_payload_fields, do: name
      defstruct for %Core.Codec.Field{name: name} <- @es_payload_fields, do: name

      @type t :: %__MODULE__{unquote_splicing(Core.Es.Event.Payload.typespec(@es_payload_fields))}

      @doc false
      @spec __es_payload_fields__() :: [Core.Codec.Field.t()]

      def __es_payload_fields__, do: @es_payload_fields

      @doc "Собрать нагрузку: поля позиционно, в порядке объявления."
      @spec new(unquote_splicing(Keyword.values(Core.Codec.Field.typespec(@es_payload_fields)))) :: t()

      def new(unquote_splicing(Core.Codec.Plugin.Fields.new_args(@es_payload_fields)))
          when unquote(Core.Codec.Plugin.Fields.payload_new_guard(@es_payload_fields)),
          do: unquote(Core.Codec.Plugin.Fields.new_body(__MODULE__, @es_payload_fields))
    end
  end

  @doc false
  @spec typespec([Field.t()]) :: keyword(Macro.t())

  # Тип чтения шире типа записи (ADR-0074): после `load` в поле с `subject:` бывает уничтоженное
  # значение, а `new/N` его не принимает.
  def typespec(fields) when is_list(fields) do
    hidden = Keyword.keys(Field.subjects(fields))

    for {name, type} <- Field.typespec(fields) do
      if name in hidden, do: {name, quote(do: unquote(type) | Core.Es.Personal.Destroyed.t())}, else: {name, type}
    end
  end
end
