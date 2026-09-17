defmodule Consumer.S.Repo do
  @moduledoc "Репозиторий event-sourced агрегата через `Core.Config.repo!/1`, как в usecase."

  alias Consumer.Account
  alias Consumer.Order
  alias Core.Context
  alias Core.Pagination

  require Core.Config

  @repo Core.Config.repo!(Consumer.Account.Repo)

  # E1 — ID другого агрегата из паттерна
  def e1_foreign_id(%Order.ID{} = id, %Context{} = context),
    # expect: incompatible types given to Consumer.Account.Repo.Pg.get/3
    do: @repo.get(id, :current, context)

  # E1b — ID другого агрегата из `Order.ID.new()`
  def e1b_foreign_id_new(%Context{} = context),
    # expect: incompatible types given to Consumer.Account.Repo.Pg.get/3
    do: @repo.get(Order.ID.new(), :current, context)

  # E2 — целое вместо `%Version{}` / `:current`
  def e2_integer_version(%Account.ID{} = id, %Context{} = context),
    # expect: incompatible types given to Consumer.Account.Repo.Pg.get/3
    do: @repo.get(id, 1, context)

  # E2b — строка вместо `:current`
  def e2b_string_version(%Account.ID{} = id, %Context{} = context),
    # expect: incompatible types given to Consumer.Account.Repo.Pg.get/3
    do: @repo.get(id, "*", context)

  # E3c — событие без списка в `append`
  def e3c_append_not_list(%Account.Event.Closed{} = event, %Context{} = context),
    # expect: incompatible types given to Consumer.Account.Repo.Pg.append/2
    do: @repo.append(event, context)

  # E4 — `:ok` по результату `get`
  def e4_case_get_ok(%Account.ID{} = id, %Context{} = context) do
    case @repo.get(id, :current, context) do
      {:ok, state} -> state
      # expect: the following clause will never match
      :ok -> nil
      {:error, _error} -> nil
    end
  end

  # E4b — ошибка чтения с кодом, которого `get` не отдаёт
  def e4b_case_get_not_found(%Account.ID{} = id, %Context{} = context) do
    case @repo.get(id, :current, context) do
      {:ok, state} -> state
      # expect: the following clause will never match
      {:error, %Core.Error{code: :not_found}} -> nil
      {:error, _error} -> nil
    end
  end

  # E5 — опечатка в поле состояния из `{:ok, state}` результата `get`
  def e5_get_state_typo(%Account.ID{} = id, %Context{} = context) do
    with {:ok, state} <- @repo.get(id, :current, context),
         # expect: unknown key .nmae
         do: state.nmae
  end

  # E5b — то же у `refresh`
  def e5b_refresh_state_typo(%Account{} = state, %Context{} = context) do
    {:ok, refreshed} = @repo.refresh(state, :current, context)
    # expect: unknown key .nmae
    refreshed.nmae
  end

  # E7 — `refresh` состояния другого агрегата
  def e7_refresh_foreign_state(%Order{} = state, %Context{} = context),
    # expect: incompatible types given to Consumer.Account.Repo.Pg.refresh/3
    do: @repo.refresh(state, :current, context)

  # X3 — ID другого агрегата в `page_stream`
  def x3_page_stream_foreign_id(
        %Order.ID{} = id,
        %Pagination.Limit{} = limit,
        %Pagination.Offset{} = offset,
        %Context{} = context
      ),
      # expect: incompatible types given to Consumer.Account.Repo.Pg.page_stream/4
      do: @repo.page_stream(id, limit, offset, context)

  # X3o — прежняя форма: реализация хранилища вместо репозитория агрегата
  def x3o_store_page_stream(
        %Account.ID{} = id,
        %Pagination.Limit{} = limit,
        %Pagination.Offset{} = offset,
        %Context{} = context
      ),
      # expect: Core.Es.Store.page_stream/5 is undefined or private
      do: Core.Es.Store.page_stream(Account.Event.Codec, id, limit, offset, context)

  # X3b — `:ok` по результату `page_stream`
  def x3b_case_page_stream_ok(%Account.ID{} = id, %Pagination.Limit{} = limit, %Context{} = context) do
    case @repo.page_stream(id, limit, Pagination.Offset.new!(0), context) do
      {:ok, page} -> page.count
      # expect: the following clause will never match
      :ok -> 0
      {:error, _error} -> 0
    end
  end

  # X3c — опечатка в поле страницы из `{:ok, page}` результата `page_stream`
  def x3c_page_stream_typo(%Account.ID{} = id, %Pagination.Limit{} = limit, %Context{} = context) do
    with {:ok, page} <- @repo.page_stream(id, limit, Pagination.Offset.new!(0), context),
         # expect: unknown key .cout
         do: page.cout
  end

  # E8 — `{:ok, _}` по результату `append`
  def e8_case_append_ok(%Account.Event.Closed{} = event, %Context{} = context) do
    case @repo.append([event], context) do
      :ok -> :ok
      # expect: the following clause will never match
      {:ok, _} -> :ok
      {:error, _error} -> :error
    end
  end
end
