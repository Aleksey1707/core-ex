defmodule Core.EsFixture.Account.CodecRepo.Codec do
  @moduledoc """
  Фасад репозитория для теста адреса агрегата: UUID дампится заглавными буквами, остальное — как
  `Core.CodecFixture.Internal`.

  Форма остаётся валидным `binary_id`, но отличается от `Core.Config.codec/0`; поток по такому
  адресу пуст, поэтому команда открывает счёт.
  """

  @behaviour Core.Codec

  alias Core.EsFixture.Account

  @doc "Dump значения: id счёта — заглавными, остальное — общим фасадом стенда."
  @spec dump(struct()) :: term()

  def dump(%Account.ID{} = id), do: String.upcase(Core.CodecFixture.Internal.dump(id))
  def dump(prim), do: Core.CodecFixture.Internal.dump(prim)

  @doc "Load значения — общим фасадом стенда."
  @spec load(module(), term()) :: Core.Result.t(struct())

  def load(module, value), do: Core.CodecFixture.Internal.load(module, value)

  @doc "Load значения с исключением — общим фасадом стенда."
  @spec load!(module(), term()) :: struct()

  def load!(module, value), do: Core.CodecFixture.Internal.load!(module, value)
end
