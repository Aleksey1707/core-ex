# PROTOTYPE — запуск из корня репозитория:
#   mix run --no-start .scratch/event-sourcing/prototype/es-aggregate-contract/run.exs

Code.require_file("common.exs", __DIR__)
Code.require_file("style_a.exs", __DIR__)
Code.require_file("style_b.exs", __DIR__)

defmodule Proto.Run do
  alias Core.Version
  alias Proto.Draft.ID
  alias Proto.Draft.Title
  alias Proto.Show
  alias Proto.Store

  @drivers [ProtoA.Driver, ProtoB.Driver]

  def main do
    Show.intro()
    happy_path()
    illegal()
    no_op()
    two_events()
    concurrent()
    empty_stream()
  end

  defp happy_path do
    Show.scenario(
      "1. Счастливый путь",
      "версия растёт на 1 за событие; состояние из истории = состояние после мутации"
    )

    each_style(fn d, store, id ->
      Show.line("создать «Черновик»", d.usecase(store, id, nil, {:create, title("Черновик")}))
      Show.line("переименовать (ожидаем v1)", d.usecase(store, id, v(1), {:rename, title("Черновик v2")}))
      Show.line("отправить (ожидаем v2)", d.usecase(store, id, v(2), {:submit, false}))
      {:ok, state} = d.load(store, id)
      Show.line("загружено", state)
      Show.line("согласовать → доменный вызов", d.raw(state, :approve))
      {:ok, pending} = d.prepare(state, :approve)
      Show.line("состояние после мутации", d.pending_state(pending))
      Show.line("запись", d.commit(store, pending))
      {:ok, restored} = d.load(store, id)
      Show.line("восстановлено из истории", restored)
      Show.line("совпадает с состоянием после мутации", d.pending_state(pending) == restored)
      Show.stream(store, id)
    end)
  end

  defp illegal do
    Show.scenario("2. Недопустимая операция", "согласовать черновик в статусе :new — ошибка, событий нет")

    each_style(fn d, store, id ->
      :ok = d.usecase(store, id, nil, {:create, title("Черновик")})
      {:ok, state} = d.load(store, id)
      Show.line("загружено", state)
      Show.line("согласовать → доменный вызов", d.raw(state, :approve))
      Show.line("usecase согласовать (ожидаем v1)", d.usecase(store, id, v(1), :approve))
      Show.stream(store, id)
    end)
  end

  defp no_op do
    Show.scenario("3. Операция без изменений", "переименовать в то же название — что возвращает доменный вызов")

    each_style(fn d, store, id ->
      :ok = d.usecase(store, id, nil, {:create, title("Черновик")})
      {:ok, state} = d.load(store, id)
      Show.line("переименовать в то же → доменный вызов", d.raw(state, {:rename, title("Черновик")}))
      Show.line("usecase (ожидаем v1)", d.usecase(store, id, v(1), {:rename, title("Черновик")}))
      Show.stream(store, id)
    end)
  end

  defp two_events do
    Show.scenario(
      "4. Два события из одной команды",
      "отправка с автосогласованием: Approved проверяется по состоянию после Submitted"
    )

    each_style(fn d, store, id ->
      :ok = d.usecase(store, id, nil, {:create, title("Черновик")})
      {:ok, state} = d.load(store, id)
      Show.line("отправить с автосогласованием → вызов", d.raw(state, {:submit, true}))
      {:ok, pending} = d.prepare(state, {:submit, true})
      Show.line("запись", d.commit(store, pending))
      Show.line("загружено", d.load(store, id))
      Show.stream(store, id)
    end)
  end

  defp concurrent do
    Show.scenario("5. Конкурентная запись", "оба прочитали v2; первая запись проходит, вторая — :version_mismatch")

    each_style(fn d, store, id ->
      :ok = d.usecase(store, id, nil, {:create, title("Черновик")})
      :ok = d.usecase(store, id, v(1), {:rename, title("Черновик v2")})
      {:ok, first} = d.load(store, id)
      {:ok, second} = d.load(store, id)
      Show.line("оба загрузили версию", {first.version.value, second.version.value})
      {:ok, first_pending} = d.prepare(first, {:rename, title("Первый")})
      Show.line("первый пишет", d.commit(store, first_pending))
      {:ok, second_pending} = d.prepare(second, {:rename, title("Второй")})
      Show.line("второй пишет", d.commit(store, second_pending))
      Show.line("usecase со старой версией (v2)", d.usecase(store, id, v(2), {:rename, title("Третий")}))
      Show.stream(store, id)
    end)
  end

  defp empty_stream do
    Show.scenario(
      "6. Пустой поток",
      "свёртка []; чтение и команда по несуществующему id; повторное создание того же id"
    )

    each_style(fn d, store, id ->
      Show.line("свёртка []", d.fold_empty())
      Show.line("загрузить несуществующий", d.load(store, id))
      Show.line("usecase переименовать несуществующий", d.usecase(store, id, :current, {:rename, title("X")}))
      Show.line("создать", d.usecase(store, id, nil, {:create, title("Черновик")}))
      Show.line("создать ещё раз тот же id", d.usecase(store, id, nil, {:create, title("Дубль")}))
      Show.stream(store, id)
    end)
  end

  defp each_style(scenario) do
    Enum.each(@drivers, fn driver ->
      Show.style(driver)
      scenario.(driver, Store.start(), ID.new())
    end)
  end

  defp title(value), do: Title.new!(value)
  defp v(value), do: Version.new!(value)
end

Proto.Run.main()
