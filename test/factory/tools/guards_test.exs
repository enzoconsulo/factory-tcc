defmodule Factory.Tools.GuardsTest do
  @moduledoc """
  One known way of killing the runtime per test, and the refuse × warn asymmetry. Both guards
  are pure, so exhaustive testing is cheap.
  """

  use ExUnit.Case, async: true

  alias Factory.Tools.Guards

  describe "process guard: refuses every way of killing the runtime" do
    test "taskkill by beam image name" do
      assert {:refused, :would_kill_runtime, _} =
               Guards.check_process("taskkill /F /IM beam.exe")
    end

    test "taskkill by erl name" do
      assert {:refused, :would_kill_runtime, _} = Guards.check_process("taskkill /IM erl.exe")
    end

    test "Stop-Process by beam name" do
      assert {:refused, :would_kill_runtime, _} =
               Guards.check_process("Stop-Process -Name beam")
    end

    test "pkill beam" do
      assert {:refused, :would_kill_runtime, _} = Guards.check_process("pkill beam.smp")
    end

    test "killall erl" do
      assert {:refused, :would_kill_runtime, _} = Guards.check_process("killall erl")
    end

    test "taskkill by the mix name itself" do
      assert {:refused, :would_kill_runtime, _} = Guards.check_process("taskkill /IM mix.bat")
    end

    test "epmd also brings the node down" do
      assert {:refused, :would_kill_runtime, _} = Guards.check_process("pkill epmd")
    end

    test "indiscriminate kill by wildcard" do
      assert {:refused, :indiscriminate_kill, _} =
               Guards.check_process("taskkill /F /IM *")
    end

    test "kill -9 -1 kills everything of the user" do
      assert {:refused, :indiscriminate_kill, _} = Guards.check_process("kill -9 -1")
    end

    test "the refusal explains what would happen, not only that it was refused" do
      {:refused, _, explanation} = Guards.check_process("taskkill /F /IM beam.exe")

      assert explanation =~ "the agent dies with it"
      assert String.length(explanation) > 40
    end
  end

  describe "process guard: proof of ownership" do
    test "ALLOWS killing a PID the factory launched" do
      assert :allowed = Guards.check_process("taskkill /PID 4242 /T /F", [4242])
    end

    test "allows killing several PIDs if all belong to the factory" do
      assert :allowed = Guards.check_process("taskkill /PID 100 /PID 200", [100, 200, 300])
    end

    test "refuses a PID the factory did NOT launch" do
      assert {:refused, :no_ownership_proof, explanation} =
               Guards.check_process("taskkill /PID 9999 /T /F", [4242])

      assert explanation =~ "9999"
    end

    test "refuses when ONE of the PIDs is foreign" do
      assert {:refused, :no_ownership_proof, _} =
               Guards.check_process("taskkill /PID 100 /PID 9999", [100])
    end

    test "refuses a kill with no PID at all" do
      assert {:refused, :no_target, _} = Guards.check_process("taskkill /F", [4242])
    end

    test "with no launched list, no PID is owned" do
      assert {:refused, :no_ownership_proof, _} =
               Guards.check_process("taskkill /PID 4242")
    end

    test "kill -TERM with a factory PID passes" do
      assert :allowed = Guards.check_process("kill -TERM 555", [555])
    end
  end

  describe "process guard: what is NOT a kill passes" do
    test "ordinary commands are not blocked" do
      assert :allowed = Guards.check_process("mix test")
      assert :allowed = Guards.check_process("git status")
      assert :allowed = Guards.check_process("npm install")
    end

    test "a word that only CONTAINS a runtime name does not trigger the runtime detector" do
      # `taskkill /IM beamer.exe` is still refused (kill by name, no PID), but never as
      # `:would_kill_runtime`.
      assert {:refused, :no_target, _} = Guards.check_process("taskkill /IM beamer.exe", [])
      assert :allowed = Guards.check_process("echo superlative")
    end

    test "mentioning beam without killing anything passes" do
      assert :allowed = Guards.check_process("echo 'beam runs here'")
    end
  end

  describe "tooling guard: WARNS, never refuses" do
    test "the result is a list of warnings, not a verdict" do
      warnings = Guards.check_tooling("curl https://example.com/x.json")

      assert is_list(warnings)
      assert length(warnings) == 1
      refute match?({:refused, _, _}, warnings)
    end

    test "the warning says what to use instead, not only that it is wrong" do
      [warning] = Guards.check_tooling("curl https://example.com")

      assert warning.use =~ "Provider"
      assert warning.use =~ "adapter"
      assert warning.text =~ "RAN anyway"
    end

    test "warns about a loose battery stage" do
      [warning] = Guards.check_tooling("mix credo --strict")
      assert warning.use =~ "ci.json"
    end

    test "warns about killing processes by hand" do
      [warning] = Guards.check_tooling("taskkill /PID 123")
      assert warning.use =~ "ProcessTree"
    end

    test "warns about a commit outside the flow" do
      [warning] = Guards.check_tooling("git commit -m 'x'")
      assert warning.use =~ "publishing"
    end

    test "a clean command produces no warning" do
      assert [] = Guards.check_tooling("mix factory.ci --fast")
      assert [] = Guards.check_tooling("ls -la")
    end

    test "one command can trigger more than one warning" do
      warnings = Guards.check_tooling("curl https://x.com && git commit -m y")
      assert length(warnings) == 2
    end

    test "every catalog entry declares tool, replacement and reason" do
      for entry <- Guards.catalog() do
        assert entry.hints != []
        assert String.trim(entry.tool) != ""
        assert String.trim(entry.use) != ""
        assert String.trim(entry.reason) != ""
      end
    end
  end

  describe "both guards are PURE" do
    test "the code does no I/O at all" do
      source = File.read!("lib/factory/tools/guards.ex")

      for forbidden <- ~w[File System.cmd Port :file :os IO Process Application Ecto] do
        pattern = ~r/(?<![A-Za-z0-9_.])#{Regex.escape(forbidden)}[.(]/

        refute Regex.match?(pattern, source),
               "Guards uses #{forbidden}. Both guards are pure: that is why they can be " <>
                 "tested exhaustively, and all the judgement lives in them."
      end
    end

    test "the same input always gives the same output" do
      command = "taskkill /PID 4242 /T /F"

      assert Guards.check_process(command, [4242]) ==
               Guards.check_process(command, [4242])

      assert Guards.check_tooling("curl x") == Guards.check_tooling("curl x")
    end

    test "the I/O detector works and does not pass vacuously" do
      pattern = ~r/(?<![A-Za-z0-9_.])File[.(]/

      assert Regex.match?(pattern, "File.read!(x)")
      refute Regex.match?(pattern, "MyFile.read!(x)")
    end
  end
end
