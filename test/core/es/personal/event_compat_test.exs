defmodule Core.Es.Personal.EventCompatTest do
  use Core.Es.EventCompatCase,
    event_codec: Core.Es.Personal.Event.Codec,
    async: true
end
