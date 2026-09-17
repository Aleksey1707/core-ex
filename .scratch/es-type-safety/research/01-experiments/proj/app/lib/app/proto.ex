defprotocol App.Proto do
  def dump(x)
end

defimpl App.Proto, for: Integer do
  def dump(x), do: x
end

defimpl App.Proto, for: App.Local do
  def dump(local), do: local.missing_field
end
