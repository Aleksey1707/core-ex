defmodule Core.Telemetry do
  @moduledoc """
  Имена telemetry-событий Core.

  Префикс задаётся потребителем — `Core.Config.telemetry_prefix/0`
  (`config :core, telemetry_prefix: [:my_app]`, по умолчанию `[otp_app()]`).
  Суффикс задаёт вызывающий: `Telemetry.event([:outbox, :poller, :cycle])`.

  Резолв рантаймовый: библиотека компилируется один раз на все приложения,
  а префикс у каждого свой.
  """

  alias Core.Config

  @doc "Полное имя события: префикс приложения + суффикс."
  @spec event([atom()]) :: [atom()]

  def event(suffix) when is_list(suffix), do: Config.telemetry_prefix() ++ suffix

  @doc """
  Обернуть работу в `:telemetry.span/3` с префиксом приложения.

  Даёт события `<prefix>.<suffix>.start` / `.stop` / `.exception`; `fun` возвращает
  `{result, metadata}` — как того требует `:telemetry.span/3`.
  """
  @spec span([atom()], :telemetry.event_metadata(), (-> {result, :telemetry.event_metadata()})) ::
          result
        when result: var

  def span(suffix, metadata, fun) when is_list(suffix) and is_map(metadata) do
    :telemetry.span(event(suffix), metadata, fun)
  end
end
