defmodule Core.ViewFixture do
  @moduledoc false

  # Представления живут здесь, а не в тест-файле: точность сгенерированных типов
  # проверяется по байткоду (`Code.Typespec.fetch_types/1`), а он есть только у
  # модулей, скомпилированных в ebin.

  defmodule ID do
    @moduledoc false

    use Core.Prim.UUID, name: "Идентификатор", version: 4
  end

  defmodule Name do
    @moduledoc false

    use Core.Prim.String, name: "Название", min_len: 1, max_len: 50
  end

  defmodule CreatedAt do
    @moduledoc false

    use Core.Prim.DateTime, name: "Дата создания"
  end

  defmodule MeasuredAt do
    @moduledoc false

    use Core.Prim.DateTime, name: "Момент замера", precision: :microsecond
  end

  defmodule Day do
    @moduledoc false

    use Core.Prim.Date, name: "Дата"
  end

  defmodule Weight do
    @moduledoc false

    use Core.Prim.Decimal, name: "Вес", min: 0
  end

  defmodule Status do
    @moduledoc """
    Статус фикстуры

    | Значение | Описание |
    |---|---|
    | `:new` | создан |
    | `:done` | завершён |
    """

    use Core.Enum, name: "Статус", values: ~w(new done)a
  end

  defmodule Specs do
    @moduledoc false

    @doc false
    def payload_spec do
      {:map, %{measured_at: {:prim, Core.ViewFixture.MeasuredAt}}}
    end
  end

  defmodule Nested do
    @moduledoc false

    use Core.View,
      fields: [
        id: [prim: Core.ViewFixture.ID],
        name: [prim: Core.ViewFixture.Name]
      ]
  end

  defmodule Sample do
    @moduledoc false

    use Core.View,
      fields: [
        id: [prim: Core.ViewFixture.ID],
        name: [prim: Core.ViewFixture.Name],
        status: [enum: Core.ViewFixture.Status],
        version: [type: :pos_integer],
        active: [type: :boolean],
        weight: [prim: Core.ViewFixture.Weight, optional: true],
        day: [prim: Core.ViewFixture.Day, optional: true],
        nested: [view: Core.ViewFixture.Nested, optional: true],
        children: [list: [view: Core.ViewFixture.Nested]],
        tags: [list: [type: :string]],
        payload: [jsonb: {Core.ViewFixture.Specs, :payload_spec}],
        marks: [list: [form: :mark]],
        created_at: [prim: Core.ViewFixture.CreatedAt],
        closed_at: [prim: Core.ViewFixture.CreatedAt, optional: true]
      ],
      forms: [
        mark: [
          code: [type: :string],
          at: [prim: Core.ViewFixture.CreatedAt],
          by: [prim: Core.ViewFixture.ID, optional: true]
        ]
      ]
  end

  defmodule Plain do
    @moduledoc false

    use Core.View,
      fields: [
        status: [enum: Core.ViewFixture.Status],
        version: [type: :pos_integer]
      ]
  end

  # Фикстурные представления не входят в `Core.CodecFixture` plugins, поэтому у них свой
  # фасад: вложенный View дампится через фасад, а тот обязан знать его плагин.
  defmodule OutCodec do
    @moduledoc false

    use Core.Codec.Facade,
      prim: Core.CodecFixture.Prim.External,
      plugins: [
        Core.ViewFixture.Nested.Codec,
        Core.ViewFixture.Plain.Codec,
        Core.ViewFixture.Sample.Codec
      ]
  end

  defmodule InCodec do
    @moduledoc false

    use Core.Codec.Facade,
      prim: Core.CodecFixture.Prim.Internal,
      plugins: [
        Core.ViewFixture.Nested.Codec,
        Core.ViewFixture.Plain.Codec,
        Core.ViewFixture.Sample.Codec
      ]
  end
end
