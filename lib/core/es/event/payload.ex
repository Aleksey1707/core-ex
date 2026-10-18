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

  Спека полей — та же, что у Codec-плагина (`Core.Codec.Plugin.Fields`), без `default:`:
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
  - `__es_payload_fields__/0` — спека для `Core.Es.Event.Codec`.

  Кодирует такую нагрузку `Core.Es.Event.Codec` события: её клаузы он выводит сам. В фасаде
  нагрузка не регистрируется.

  Макрос занимает в модуле нагрузки имя `@es_payload_fields`.
  """

  alias Core.Codec.Plugin.Fields
  alias Core.Helper

  @doc "Объявить нагрузку события по полям (`fields:`)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(opts, ~w(fields)a, [], "Es.Event.Payload")

      @es_payload_fields Core.Codec.Plugin.Fields.payload_fields!(__MODULE__, Keyword.fetch!(opts, :fields))

      case Keyword.keys(Core.Codec.Plugin.Fields.subjects(@es_payload_fields)) do
        [] -> :ok
        hidden -> @derive {Inspect, except: hidden}
      end

      @enforce_keys for {name, _spec, false, _wire, _default, _subject} <- @es_payload_fields, do: name
      defstruct Enum.map(@es_payload_fields, &elem(&1, 0))

      @type t :: %__MODULE__{unquote_splicing(Core.Es.Event.Payload.typespec(@es_payload_fields))}

      @doc false
      @spec __es_payload_fields__() :: [Core.Codec.Plugin.Fields.field()]

      def __es_payload_fields__, do: @es_payload_fields

      @doc "Собрать нагрузку: поля позиционно, в порядке объявления."
      @spec new(unquote_splicing(Keyword.values(Core.Codec.Plugin.Fields.typespec(@es_payload_fields)))) :: t()

      def new(unquote_splicing(Core.Codec.Plugin.Fields.new_args(@es_payload_fields)))
          when unquote(Core.Codec.Plugin.Fields.payload_new_guard(@es_payload_fields)),
          do: unquote(Core.Codec.Plugin.Fields.new_body(__MODULE__, @es_payload_fields))
    end
  end

  @doc false
  @spec typespec([Fields.field()]) :: keyword(Macro.t())

  # Тип чтения шире типа записи (ADR-0074): после `load` в поле с `subject:` бывает уничтоженное
  # значение, а `new/N` его не принимает.
  def typespec(fields) when is_list(fields) do
    hidden = Keyword.keys(Fields.subjects(fields))

    for {name, type} <- Fields.typespec(fields) do
      if name in hidden, do: {name, quote(do: unquote(type) | Core.Es.Personal.Destroyed.t())}, else: {name, type}
    end
  end
end
