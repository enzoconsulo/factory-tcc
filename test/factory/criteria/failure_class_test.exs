defmodule Factory.Criteria.FailureClassTest do
  @moduledoc """
  `classify/1` holds the whole judgement of the mechanical pass, so it is tested exhaustively.
  The key block is "the hard case": `Cannot find module` means opposite things depending on
  whether the target exists on disk.
  """

  use ExUnit.Case, async: true

  alias Factory.Criteria
  alias Factory.Criteria.FailureClass

  doctest Factory.Criteria.FailureClass

  @root File.cwd!()

  defp context(attrs) do
    default = %{
      argv: ["mix", "test"],
      output: "",
      code: 1,
      timed_out: false,
      exists_on_disk: fn _path -> false end
    }

    Map.merge(default, Map.new(attrs))
  end

  defp criterion(text, command), do: %{text: text, command: command, checked: false}

  describe "broken tool — the command evaluated nothing" do
    test "ENOENT from the spawn itself" do
      assert FailureClass.classify(context(code: "ENOENT")) == :broken_tool
    end

    test "the shell does not know the binary, in any language" do
      messages = [
        "bash: cargo: command not found",
        "'cargo' is not recognized as an internal or external command, operable program",
        "'cargo' nao e reconhecido como um comando interno ou externo",
        "Error: spawn cargo ENOENT"
      ]

      for output <- messages do
        assert FailureClass.classify(context(output: output)) == :broken_tool,
               "should be a tool problem: #{output}"
      end
    end

    test "UNIVERSAL misuse exit codes, regardless of the binary" do
      # 127 is POSIX and 9009 is cmd.exe: they come from the interpreter, not the program.
      for code <- [127, 9009] do
        assert FailureClass.classify(context(code: code)) == :broken_tool
      end
    end

    test "a binary-specific misuse code also requires the message" do
      with_message =
        context(argv: ["node", "--test"], code: 9, output: "node: bad option: --test")

      without_message =
        context(argv: ["node", "--test"], code: 9, output: "3 tests failed")

      assert FailureClass.classify(with_message) == :broken_tool
      assert FailureClass.classify(without_message) == :delivery
    end

    test "invalid option, in any binary" do
      messages = [
        "error: unknown option '--jobs'",
        "unrecognized option: --coverage",
        "invalid option -- 'z'",
        "fatal: unrecognized argument: --invalid-option",
        "unknown argument: --x",
        "unknown flag: --y",
        "npm ERR! Missing script: \"tests\"",
        "** (Mix) The task \"does_not_exist\" could not be found"
      ]

      for output <- messages do
        assert FailureClass.classify(context(output: output)) == :broken_tool,
               "should be a tool problem: #{output}"
      end
    end

    test "the Windows extension does not hide the binary from the code table" do
      assert FailureClass.classify(
               context(argv: ["node.exe", "--test"], code: 9, output: "bad option")
             ) == :broken_tool
    end
  end

  describe "the hard case — same message, opposite meanings" do
    test "a target that EXISTS and fails to load is a tool problem" do
      ctx =
        context(
          argv: ["node", "--test", "tests"],
          output: "Error: Cannot find module 'C:\\p\\tests'",
          exists_on_disk: fn _path -> true end
        )

      assert FailureClass.classify(ctx) == :broken_tool
    end

    test "a target that does NOT exist is a delivery failure" do
      ctx =
        context(
          argv: ["node", "--test", "tests/turn.test.js"],
          output: "Error: Cannot find module 'C:/p/tests/turn.test.js'",
          exists_on_disk: fn _path -> false end
        )

      assert FailureClass.classify(ctx) == :delivery
    end

    test "a module that is not a command argument is a task failure, even if it exists" do
      ctx =
        context(
          argv: ["node", "--test", "tests/"],
          output: "Cannot find module '../src/board.js'",
          exists_on_disk: fn _path -> true end
        )

      assert FailureClass.classify(ctx) == :delivery
    end

    test "a flag never counts as a target" do
      ctx =
        context(
          argv: ["node", "--test-reporter", "tests"],
          output: "can't open file '--test-reporter'",
          exists_on_disk: fn _path -> true end
        )

      assert FailureClass.classify(ctx) == :delivery
    end

    test "recognises the target in several ecosystems, not just Node" do
      cases = [
        {["python", "missing.py"], "python: can't open file 'missing.py'"},
        {["python", "missing.py"], "No such file or directory: 'missing.py'"},
        {["go", "test", "./package"], "no Go files in ./package"},
        {["node", "app.mjs"], "Cannot find package 'app.mjs'"}
      ]

      for {argv, output} <- cases do
        ctx = context(argv: argv, output: output, exists_on_disk: fn _p -> true end)

        assert FailureClass.classify(ctx) == :broken_tool,
               "should be a tool problem: #{output}"
      end
    end

    test "the Windows path separator does not break the comparison" do
      ctx =
        context(
          argv: ["node", "--test", "tests/unit"],
          output: "Cannot find module 'C:\\project\\tests\\unit'",
          exists_on_disk: fn _path -> true end
        )

      assert FailureClass.classify(ctx) == :broken_tool
    end
  end

  describe "environment — the machine got in the way" do
    test "a timeout is not a delivery failure" do
      ctx = context(timed_out: true, code: nil, output: "")

      assert FailureClass.classify(ctx) == :environment
      refute FailureClass.counts_cycle?(:environment)
    end

    test "a timeout wins even with output that looks like a failure" do
      ctx = context(timed_out: true, output: "3 tests, 2 failures")

      assert FailureClass.classify(ctx) == :environment
    end

    test "a process killed by a signal" do
      assert FailureClass.classify(context(signal: "SIGKILL")) == :environment
    end

    test "a native Windows crash arrives as an error NTSTATUS" do
      for code <- [0xC0000409, 0xC0000005, 0xC0000000] do
        assert FailureClass.classify(context(code: code)) == :environment
      end
    end

    test "a code below the NTSTATUS floor is not a native crash" do
      assert FailureClass.classify(context(code: 0xBFFFFFFF)) == :delivery
    end

    test "resource exhaustion, across stacks" do
      messages = [
        "Error: ENOMEM: not enough memory",
        "EMFILE: too many open files",
        "listen EADDRINUSE: address already in use :::4000",
        "EBUSY: resource busy or locked",
        "FATAL ERROR: JavaScript heap out of memory",
        "runtime: out of memory",
        "MemoryError"
      ]

      for output <- messages do
        assert FailureClass.classify(context(output: output)) == :environment,
               "should be environment: #{output}"
      end
    end

    test "resource exhaustion is checked LAST" do
      # Otherwise a broken criterion whose output mentions EBUSY would be rerun forever.
      ctx = context(output: "unknown option '--x'\nWarning: EBUSY on temp file")

      assert FailureClass.classify(ctx) == :broken_tool
    end
  end

  describe "delivery — the command ran and the result is wrong" do
    test "an ordinary suite failure" do
      ctx = context(output: "5 tests, 2 failures", code: 1)

      assert FailureClass.classify(ctx) == :delivery
      assert FailureClass.counts_cycle?(:delivery)
    end

    test "when in doubt, :delivery" do
      assert FailureClass.classify(context(output: "", code: 1)) == :delivery
      assert FailureClass.classify(context(output: "something went wrong", code: 42)) == :delivery
    end

    test "a nil code with no signal is still delivery" do
      assert FailureClass.classify(context(code: nil)) == :delivery
    end

    test "a context without :signal and :exists_on_disk does not raise" do
      assert FailureClass.classify(%{
               argv: ["mix", "test"],
               output: "1 failure",
               code: 1,
               timed_out: false
             }) == :delivery
    end
  end

  describe "the consequences are opposite" do
    test "only :delivery spends a cycle" do
      assert FailureClass.counts_cycle?(:delivery)
      refute FailureClass.counts_cycle?(:broken_tool)
      refute FailureClass.counts_cycle?(:environment)
    end

    test "only :environment is worth rerunning" do
      assert FailureClass.rerun?(:environment)
      refute FailureClass.rerun?(:broken_tool)
      refute FailureClass.rerun?(:delivery)
    end

    test "each class points to a different fixer" do
      assert FailureClass.fixer(:broken_tool) == :orchestrator_fixes_criterion
      assert FailureClass.fixer(:environment) == :machine
      assert FailureClass.fixer(:delivery) == :builder
    end

    test "the tool explanation says the CRITERION needs fixing" do
      assert FailureClass.explain(:broken_tool) =~ "the criterion itself needs fixing"
      assert FailureClass.explain(:delivery) =~ "result is wrong"
      assert FailureClass.explain(:environment) =~ "machine got in the way"
    end
  end

  describe "integrated with the mechanical pass" do
    test "an invalid command becomes :inconclusive by tool and spends no cycle" do
      results =
        Criteria.run([criterion("runs the battery", "git log --invalid-option")], @root)

      assert [result] = results
      assert result.state == :inconclusive
      assert result.class == :broken_tool
      refute Criteria.failed?(results)
      assert Criteria.cycles_spent(results) == 0
      assert [_] = Criteria.broken_criteria(results)
    end

    test "a timeout reruns ONCE and the rerun is counted" do
      # Never finishes by itself (schedules a ~28h timer), so it exceeds any short timeout
      # structurally rather than by machine speed. `=>` is avoided: a bare `>` is already
      # rejected by the allowlist as chaining.
      endless_command = "node -e setTimeout(function(){},99999999)"

      results =
        Criteria.run([criterion("the suite", endless_command)], @root, timeout: 1)

      assert [result] = results
      assert result.state == :inconclusive
      assert result.class == :environment
      assert result.rerun
      assert Criteria.reruns(results) == 1

      refute Criteria.failed?(results)
      assert Criteria.cycles_spent(results) == 0
    end

    test "a passing command neither reruns nor becomes inconclusive" do
      results = Criteria.run([criterion("repo", "git rev-parse --git-dir")], @root)

      assert [%{state: :passed, rerun: false, class: nil}] = results
      assert Criteria.reruns(results) == 0
      assert Criteria.inconclusive(results) == []
    end

    test "a real failure still fails and spends a cycle" do
      results = Criteria.run([criterion("object", "git cat-file -t 0000000000")], @root)

      assert [%{state: :failed, class: :delivery}] = results
      assert Criteria.failed?(results)
      assert Criteria.cycles_spent(results) == 1
    end

    test "the whole pass spends at most ONE cycle, even with several failures" do
      results =
        Criteria.run(
          [
            criterion("one", "git cat-file -t 0000000000"),
            criterion("two", "git cat-file -t 1111111111")
          ],
          @root
        )

      assert Enum.all?(results, &(&1.state == :failed))
      assert Criteria.cycles_spent(results) == 1
    end
  end

  describe "the report tells the difference" do
    test "inconclusive is reported as [judged] with the action, not as a failure" do
      text =
        [criterion("battery", "git log --invalid-option")]
        |> Criteria.run(@root)
        |> Criteria.report()

      assert text =~ "- [judged] battery"
      assert text =~ "the criterion itself needs fixing"
      assert text =~ "Does not fail the task"
      refute text =~ "**FAILED**"
    end

    test "the warning line separates the level from the ACTION" do
      text =
        [criterion("battery", "git log --invalid-option")]
        |> Criteria.run(@root)
        |> Criteria.report()

      assert text =~ "1 INCONCLUSIVE criteria"
      assert text =~ "by broken_tool"
      assert text =~ "no builder may change it"
    end

    test "without inconclusive results the warning line does not appear" do
      text =
        [criterion("repo", "git rev-parse --git-dir")]
        |> Criteria.run(@root)
        |> Criteria.report()

      refute text =~ "INCONCLUSIVE"
    end

    test "the ladder keeps THREE levels, not four" do
      text =
        [criterion("battery", "git log --invalid-option"), criterion("judges", nil)]
        |> Criteria.run(@root)
        |> Criteria.report()

      refute text =~ "[inconclusive]"
      assert text =~ "Proof levels: 2 judged (of 2)."
    end
  end
end
