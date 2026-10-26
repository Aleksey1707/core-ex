# `open_api_spex` объявлен в библиотеке `optional: true` (ADR-0064): схемы события собираются только
# у приложения, у которого он есть. Модули схем порождает `use Core.Web.Event` в пространстве
# приложения, их тела строят функции этого модуля. Приложение с `open_api_spex` при `core`, собранном
# без него, получает `CompileError` в `use`.
if Code.ensure_loaded?(OpenApiSpex) do
  defmodule Core.Web.Event.Schema do
    @moduledoc false

    # Вид сведения → суффикс названия схемы вида, описание.
    @variants [
      text: {"Text", "Текст: строка, подпись значения, «Да» / «Нет»"},
      number: {"Number", "Число строкой с десятичной точкой; единица — в подписи"},
      date: {"Date", "Дата"},
      datetime: {"DateTime", "Дата-время"},
      user: {"User", "Ссылка на учётную запись"},
      ref: {"Ref", "Ссылка на запись: вид записи, id и текущее имя"},
      group: {"Group", "Сведения вложенного значения"},
      list: {"List", "Элементы одного вида без подписи; у map'ы с id в ключах — группы «ключ — значение»"},
      set: {"Set", "Элементы множества одного вида без подписи, по возрастанию значения"},
      map: {"Map", "Пары словаря: ключ и значение — сведения своих видов без подписи"},
      change: {"Change", "Изменение: было и стало — сведения без подписи"},
      destroyed: {"Destroyed", "Уничтоженное ПДн-значение: подпись без значения"}
    ]

    @variant_kinds Keyword.keys(@variants)

    # ===== событие =====

    @doc false
    @spec event(String.t(), module() | nil, module() | nil) :: OpenApiSpex.Schema.t()

    def event(title, user, detail) when is_binary(title) and is_atom(user) and is_atom(detail) do
      properties = Map.merge(envelope(user), labels(detail))

      OpenApiSpex.build_schema(
        %{
          title: title,
          description: "Событие страницы событий",
          type: :object,
          properties: properties,
          required: Map.keys(properties)
        },
        struct?: false
      )
    end

    # ---

    defp envelope(user) do
      %{
        id: %OpenApiSpex.Schema{type: :string, description: "Идентификатор события"},
        aggregateId: %OpenApiSpex.Schema{type: :string, description: "Идентификатор агрегата"},
        aggregateVersion: %OpenApiSpex.Schema{type: :integer, minimum: 1, description: "Версия агрегата после события"},
        type: %OpenApiSpex.Schema{type: :string, description: "Тег события"},
        payload: %OpenApiSpex.Schema{
          nullable: true,
          description:
            "Нагрузка события, ключи — camelCase; уничтоженное ПДн-значение " <> ~s(поля — {"$destroyed": true})
        },
        at: %OpenApiSpex.Schema{type: :string, format: :"date-time", description: "Момент события"},
        by: by(user)
      }
    end

    defp by(nil), do: %OpenApiSpex.Schema{type: :string, description: "Идентификатор автора"}
    defp by(user), do: user

    defp labels(nil), do: %{}

    defp labels(detail) do
      %{
        title: %OpenApiSpex.Schema{type: :string, description: "Название события"},
        details: %OpenApiSpex.Schema{type: :array, items: detail, description: "Сведения события"}
      }
    end

    # ===== сведение =====

    @doc false
    @spec detail(String.t(), keyword(module())) :: OpenApiSpex.Schema.t()

    def detail(title, variants) when is_binary(title) and is_list(variants) do
      OpenApiSpex.build_schema(
        %{
          title: title <> "Detail",
          description: "Сведение события: вид — в `kind`",
          type: :object,
          oneOf: Keyword.values(variants),
          discriminator: %OpenApiSpex.Discriminator{
            propertyName: "kind",
            mapping: Map.new(variants, fn {kind, _module} -> {"#{kind}", path(variant_title(title, kind))} end)
          }
        },
        struct?: false
      )
    end

    @doc false
    @spec variant(String.t(), atom(), module() | nil) :: OpenApiSpex.Schema.t()

    def variant(title, kind, user) when is_binary(title) and kind in @variant_kinds and is_atom(user) do
      {_suffix, description} = Keyword.fetch!(@variants, kind)

      OpenApiSpex.build_schema(
        %{
          title: variant_title(title, kind),
          description: description,
          type: :object,
          properties:
            Map.merge(
              %{
                label: %OpenApiSpex.Schema{
                  type: :string,
                  description: "Подпись; нет у элемента списка и стороны изменения"
                },
                kind: %OpenApiSpex.Schema{type: :string, enum: ["#{kind}"]}
              },
              properties(kind, ref(title <> "Detail"), user)
            ),
          required: required(kind)
        },
        struct?: false
      )
    end

    # ---

    defp variant_title(title, kind) do
      {suffix, _description} = Keyword.fetch!(@variants, kind)

      title <> "Detail" <> suffix
    end

    defp ref(title), do: %OpenApiSpex.Reference{"$ref": path(title)}

    defp path(title), do: "#/components/schemas/#{title}"

    defp properties(:text, _detail, _user), do: %{value: %OpenApiSpex.Schema{type: :string, nullable: true}}

    defp properties(:number, _detail, _user),
      do: %{value: %OpenApiSpex.Schema{type: :string, nullable: true, example: "4.5"}}

    defp properties(:date, _detail, _user),
      do: %{value: %OpenApiSpex.Schema{type: :string, format: :date, nullable: true}}

    defp properties(:datetime, _detail, _user),
      do: %{value: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true}}

    defp properties(:user, _detail, user), do: %{value: %OpenApiSpex.Schema{allOf: [user], nullable: true}}

    defp properties(:ref, _detail, _user) do
      %{
        value: %OpenApiSpex.Schema{
          type: :object,
          nullable: true,
          properties: %{
            entity: %OpenApiSpex.Schema{type: :string, description: "Вид записи, camelCase"},
            id: %OpenApiSpex.Schema{type: :string, description: "Идентификатор записи"},
            name: %OpenApiSpex.Schema{type: :string, nullable: true, description: "Текущее имя записи"}
          },
          required: ~w(entity id name)a
        }
      }
    end

    defp properties(kind, detail, _user) when kind in ~w(group list set)a,
      do: %{value: %OpenApiSpex.Schema{type: :array, items: detail, nullable: true}}

    defp properties(:map, detail, _user) do
      %{
        value: %OpenApiSpex.Schema{
          type: :array,
          nullable: true,
          items: %OpenApiSpex.Schema{
            type: :object,
            properties: %{key: detail, value: detail},
            required: ~w(key value)a
          }
        }
      }
    end

    defp properties(:change, detail, _user), do: %{old: detail, new: detail}
    defp properties(:destroyed, _detail, _user), do: %{}

    defp required(:change), do: ~w(label kind old new)a
    defp required(:destroyed), do: ~w(kind)a
    defp required(_kind), do: ~w(kind value)a
  end
end
