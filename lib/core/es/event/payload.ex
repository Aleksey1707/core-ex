defmodule Core.Es.Event.Payload do
  @moduledoc """
  Билдер нагрузки события по полям: struct, позиционный `new`, `@type t` и спека полей
  из одной декларации.

      defmodule Payload do
        use Core.Es.Event.Payload,
          fields: [
            name: [prim: Account.Name],
            note: [prim: Account.Note, optional: true]
          ]
      end

  Спека полей — та же, что у Codec-плагина (`Core.Codec.Plugin.Fields`), без `default:`:
  событие развивается новым тегом и апкастом (ADR-0010, ADR-0020), а не дефолтом —
  `default:` даёт `CompileError`.

  Порождаются:

  - `@enforce_keys` (все поля, кроме `optional: true`) и `defstruct`;
  - `@type t` по видам полей (`optional:` — `| nil`);
  - `new/N` — поля позиционно в порядке объявления; голова проверяет вид каждого поля, как
    `dump/2` плагина по полям, так что нагрузка не того вида ловится при сборке вызывающего;
  - `__es_payload_fields__/0` — спека для `Core.Es.Event.Codec`.

  Кодирует такую нагрузку `Core.Es.Event.Codec` события: клаузы `dump_payload/2` /
  `load_payload/3` он выводит сам. В фасаде нагрузка не регистрируется.

  Макрос занимает в модуле нагрузки имя `@es_payload_fields`.
  """

  alias Core.Helper

  @doc "Объявить нагрузку события по полям (`fields:`)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(opts, ~w(fields)a, [], "Es.Event.Payload")

      @es_payload_fields Core.Codec.Plugin.Fields.payload_fields!(__MODULE__, Keyword.fetch!(opts, :fields))

      @enforce_keys for {name, _spec, false, _wire, _default} <- @es_payload_fields, do: name
      defstruct Enum.map(@es_payload_fields, &elem(&1, 0))

      @type t :: %__MODULE__{unquote_splicing(Core.Codec.Plugin.Fields.typespec(@es_payload_fields))}

      @doc false
      @spec __es_payload_fields__() :: [Core.Codec.Plugin.Fields.field()]

      def __es_payload_fields__, do: @es_payload_fields

      @doc "Собрать нагрузку: поля позиционно, в порядке объявления."
      @spec new(unquote_splicing(Keyword.values(Core.Codec.Plugin.Fields.typespec(@es_payload_fields)))) :: t()

      def new(unquote_splicing(Core.Codec.Plugin.Fields.new_args(@es_payload_fields)))
          when unquote(Core.Codec.Plugin.Fields.new_guard(@es_payload_fields)),
          do: unquote(Core.Codec.Plugin.Fields.new_body(__MODULE__, @es_payload_fields))
    end
  end
end
