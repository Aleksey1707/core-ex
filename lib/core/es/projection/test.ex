defmodule Core.Es.Projection.Test do
  @moduledoc """
  Тестовая поддержка проекций (`Core.Es.Projection`): прогон в процессе теста.

  Пачка видит события своей транзакции, поэтому запись через репозиторий и прогон идут в одной
  sandbox-транзакции теста. Тест с прогоном — `async: false`: блокировка пачки и строка чекпоинта
  держатся до конца sandbox-транзакции.
  """

  alias Core.Error
  alias Core.Es.Projection

  @doc """
  Прогнать проекции пачками до `:idle` — по очереди, без предела итераций.

  `opts` — опции `Core.Es.Projection.run_once/2`. Пачка с исходом не `:processed` и не `:idle`
  останавливает прогон: `:locked` — `{:error, :locked}`, `:outdated` — `{:error, :outdated}`,
  ошибка — как есть.
  """
  @spec run_until_idle(module() | [module()], keyword()) ::
          :ok | {:error, :locked | :outdated | Error.t()}

  def run_until_idle(projections, opts \\ [])

  def run_until_idle(projections, opts) when is_list(projections) and is_list(opts) do
    Enum.reduce_while(projections, :ok, fn projection, :ok ->
      case until_idle(projection, opts) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def run_until_idle(projection, opts) when is_atom(projection) and is_list(opts),
    do: run_until_idle([projection], opts)

  # ---

  defp until_idle(projection, opts) do
    case Projection.run_once(projection, opts) do
      :processed -> until_idle(projection, opts)
      :idle -> :ok
      :locked -> {:error, :locked}
      :outdated -> {:error, :outdated}
      {:error, %Error{}} = error -> error
    end
  end
end
