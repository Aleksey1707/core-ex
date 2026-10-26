defmodule Core.Es.Projection.ListenerTest do
  use ExUnit.Case, async: true

  alias Core.Es.Projection.Listener
  alias Core.TestRepo

  describe "опции старта" do
    test "неизвестная опция, нет обязательной, connection: не keyword — ArgumentError в start_link/1" do
      for {opts, expected} <- [
            {[repo: TestRepo, connection: [], conn: []], "unknown options [:conn]"},
            {[repo: TestRepo], "required :connection option not found"},
            {[repo: TestRepo, connection: :direct], "invalid value for :connection option: expected keyword list"}
          ] do
        %ArgumentError{message: message} = assert_raise(ArgumentError, fn -> Listener.start_link(opts) end)
        assert message =~ "Core.Es.Projection.Listener.start_link/1: #{expected}"
      end
    end
  end
end
