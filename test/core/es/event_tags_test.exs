defmodule Core.Es.EventTagsTest do
  # Тип агрегата `"core.subject"` зарезервирован библиотекой с точкой нарочно (ADR-0079): кодек
  # потребителя в snake_case с ним не совпадёт, а дубль ловит сборка фасада.
  use Core.Es.Event.TagsCase,
    otp_app: :core,
    except_types: [Core.Es.Personal.Event.Codec],
    async: true
end
