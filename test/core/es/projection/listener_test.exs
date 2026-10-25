defmodule Core.Es.Projection.ListenerTest do
  use ExUnit.Case, async: true

  alias Core.Es.Projection.Listener
  alias Core.TestRepo

  describe "опции старта" do
    test "неизвестная опция, нет обязательной, connection: не keyword — ArgumentError в init/1" do
      Process.flag(:trap_exit, true)

      for {opts, expected} <- [
            {[repo: TestRepo, connection: [], conn: []], "unknown options [:conn]"},
            {[repo: TestRepo], "required :connection option not found"},
            {[repo: TestRepo, connection: :direct], "invalid value for :connection option: expected keyword list"}
          ] do
        assert {:error, {%ArgumentError{message: message}, _stack}} = Listener.start_link(opts)
        assert message =~ "Core.Es.Projection.Listener.init/1: #{expected}"
      end
    end
  end
end
