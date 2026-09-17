# Вариант P1: `draft/1` в модуле-семействе `<Aggregate>.Event` — имитация библиотечного
# `use Core.Es.Event.Family, codec: …`: `__before_compile__` семейства грузит кодек и берёт события
# из его `tags:`.
defmodule Blind.FamilyDraft do
  defmacro __using__(opts) do
    codec = Macro.expand(Keyword.fetch!(opts, :codec), __CALLER__)

    quote do
      @family_codec unquote(codec)
      @before_compile Blind.FamilyDraft
    end
  end

  defmacro __before_compile__(env) do
    codec = Code.ensure_compiled!(Module.get_attribute(env.module, :family_codec))

    for mod <- Enum.sort(codec.__es_mods__()) do
      case mod.__es_payload__() do
        nil ->
          quote do
            def draft(unquote(mod)), do: unquote(mod)
          end

        payload ->
          quote do
            def draft(%unquote(payload){} = payload), do: {unquote(mod), payload}
          end
      end
    end
  end
end
