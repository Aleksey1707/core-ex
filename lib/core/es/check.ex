defmodule Core.Es.Check do
  @moduledoc """
  Функции-проверки: утверждение о коде потребителя, которое проверяет вывод типов при его сборке.

  `use` модуля `Core.Es.*` генерирует в модуле потребителя функцию на каждое событие, и её тело —
  литеральный вызов колбэка потребителя с аргументами, суженными паттерном:

      @doc false
      def unquote(:"evolve/2 принимает MyApp.Account.Event.Closed")(
            %MyApp.Account{} = state,
            %MyApp.Account.Event.Closed{payload: nil} = event
          ),
          do: MyApp.Account.evolve(state, event)

  Нет clause для события, опечатка в поле нагрузки, не суженной паттерном, или в ключе
  `%{state | …}` — предупреждение компилятора на этом вызове. Исполнять функцию-проверку не нужно.

  Механика одна на все проверки:

  - имя функции — нарушенное утверждение и его предмет (`"evolve/2 принимает <Event>"`):
    компилятор печатает его в месте предупреждения. Атом ограничен 255 символами, и из имени
    функции компилятор Erlang строит служебные атомы длиннее (`-inlined-<имя>/2-`), поэтому имя
    держится с запасом в 32 символа: модуль, который не помещается, укорачивается до последних
    сегментов с `…` в начале;
  - место предупреждения — строка `use`: ею размечен весь код функции;
  - `@doc false`: в документации функции нет, в `__info__(:functions)` — есть;
  - `generated: true` на функции не ставится — он погасил бы само предупреждение; в meta
    размечается только clause результата, недостижимая в корректном коде (`{:error, _}` у
    `load_payload/3`, который никогда не ошибается);
  - паттерн события задаёт только `payload:` (`event_pattern/1`): полный заголовок события
    забивает сообщение компилятора шумом.

  Почему проверка при сборке, а не тестом, — `docs/adr/0014-consumer-type-safety-by-inference.md`.
  """

  @name_limit 255 - 32

  # ===== функция-проверка =====

  @doc """
  Функция-проверка `"<claim> <subject>"(args)` с телом `body`, размеченная строкой `line`.

  Аргументы и тело собирает вызывающий макрос, `line` — строка его `use`.
  """
  @spec define(String.t(), module(), [Macro.t()], Macro.t(), pos_integer()) :: Macro.t()

  def define(claim, subject, args, body, line)
      when is_binary(claim) and is_atom(subject) and is_list(args) and is_integer(line) do
    quote do
      @doc false
      def unquote(name(claim, subject))(unquote_splicing(args)), do: unquote(body)
    end
    |> Macro.prewalk(&put_line(&1, line))
  end

  # ---

  defp name(claim, subject) do
    room = @name_limit - String.length(claim) - 1

    # Атом собирается на компиляции из модулей кода потребителя, а не из внешних данных;
    # `String.to_existing_atom/1` непригоден — имя функции-проверки появляется здесь впервые.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    String.to_atom("#{claim} #{shorten(subject, room)}")
  end

  defp shorten(subject, room) do
    full = inspect(subject)

    if String.length(full) <= room,
      do: full,
      else: "…" <> last_segments(Enum.reverse(Module.split(subject)), room - 1)
  end

  defp last_segments([segment | rest], room) do
    Enum.reduce_while(rest, String.slice(segment, -room, room), fn segment, tail ->
      joined = segment <> "." <> tail
      if String.length(joined) <= room, do: {:cont, joined}, else: {:halt, tail}
    end)
  end

  defp put_line({form, meta, args}, line) when is_list(meta), do: {form, Keyword.put(meta, :line, line), args}
  defp put_line(node, _line), do: node

  # ===== паттерн события =====

  @doc "Паттерн события `event`, суженного только по нагрузке: `%Payload{}` либо `nil`."
  @spec event_pattern(module()) :: Macro.t()

  def event_pattern(event) when is_atom(event) do
    case event.__es_payload__() do
      nil -> quote(do: %unquote(event){payload: nil})
      payload -> quote(do: %unquote(event){payload: %unquote(payload){}})
    end
  end
end
