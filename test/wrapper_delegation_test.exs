defmodule WrapperDelegationTest do
  @moduledoc """
  Test that mimics GitlabBot.Otel.ExUnitFormatter wrapper to debug
  why suite_finished might not be received when using delegation.
  """
  use ExUnit.Case

  # Mimics GitlabBot.Otel.ExUnitFormatter wrapper
  defmodule TestWrapper do
    use GenServer

    def init(opts) do
      IO.puts("[TestWrapper] init called")
      result = OpentelemetryExUnitFormatter.init(opts)
      IO.puts("[TestWrapper] init returned: #{inspect(elem(result, 0))}")

      # Register after_suite callback like pipie does
      ExUnit.after_suite(fn _result ->
        IO.puts("[TestWrapper] after_suite callback executed")
      end)

      result
    end

    # Delegate handle_cast to the real formatter
    defdelegate handle_cast(event, state), to: OpentelemetryExUnitFormatter
  end

  # Simple dummy test module
  defmodule DummyTest do
    use ExUnit.Case, register: false

    test "dummy test 1" do
      assert true
    end

    test "dummy test 2" do
      assert 1 + 1 == 2
    end
  end

  # Another dummy module to test multiple modules
  defmodule AnotherDummyTest do
    use ExUnit.Case, register: false

    test "another dummy" do
      assert :ok == :ok
    end
  end

  describe "wrapper delegation" do
    test "receives all events including suite_finished" do
      IO.puts("\n=== Starting wrapper delegation test ===")

      # Flush any pending messages
      flush_messages()

      # Configure to use wrapper
      ExUnit.configure(formatters: [TestWrapper])

      # Run dummy tests
      IO.puts("=== Running DummyTest ===")
      result = ExUnit.run([DummyTest])
      IO.puts("=== DummyTest result: #{inspect(result)} ===")

      # Reset formatters
      ExUnit.configure(formatters: [ExUnit.CLIFormatter])

      IO.puts("=== Wrapper delegation test complete ===\n")
    end

    test "receives events for multiple test modules" do
      IO.puts("\n=== Starting multi-module test ===")

      flush_messages()

      ExUnit.configure(formatters: [TestWrapper])

      IO.puts("=== Running multiple modules ===")
      result = ExUnit.run([DummyTest, AnotherDummyTest])
      IO.puts("=== Multi-module result: #{inspect(result)} ===")

      ExUnit.configure(formatters: [ExUnit.CLIFormatter])

      IO.puts("=== Multi-module test complete ===\n")
    end
  end

  defp flush_messages do
    receive do
      _msg -> flush_messages()
    after
      0 -> :ok
    end
  end
end
