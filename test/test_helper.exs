# У библиотеки нет своего OTP-приложения: процессы, которые в приложении-потребителе
# поднимает его supervisor, стартуют здесь.

{:ok, _pid} = Core.TestRepo.start_link()

:ok = Core.Clock.Test.start()

Ecto.Adapters.SQL.Sandbox.mode(Core.TestRepo, :manual)

# `lazy: true` — коннект откладывается до первого `Connection.connect/0`, поэтому
# процесс поднимается и без живого брокера (тесты `:rabbit_stream` исключены по умолчанию).
{lazy, stream_credentials} = Keyword.pop!(Application.fetch_env!(:core, Core.Mq.Stream), :lazy)

stream_opts =
  stream_credentials
  |> Core.Mq.Stream.Credentials.new()
  |> Core.Mq.Stream.Credentials.to_connection_opts()
  |> Keyword.put(:lazy, lazy)

{:ok, _pid} = Core.Mq.Stream.Connection.start_link(stream_opts)

ExUnit.start(exclude: [:rabbit_stream, :kafka])
