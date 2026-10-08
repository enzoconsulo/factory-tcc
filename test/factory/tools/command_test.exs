defmodule Factory.Tools.CommandTest do
  @moduledoc """
  The command tool, and above all the killing of the process TREE. The grandchild test is the
  one that matters: a test that only checks "the command ended" would miss orphans.
  """

  use ExUnit.Case, async: true

  alias Factory.Tools.Command
  alias Factory.Tools.ProcessTree

  @moduletag :capture_log

  setup do
    root =
      Path.join([
        File.cwd!(),
        "_build",
        "test",
        "tmp",
        "cmd-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(Path.join(root, "sub"))
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  defp windows?, do: ProcessTree.platform() == :windows

  # A command that only prints, on each platform.
  defp echo(text) do
    if windows?(), do: "echo #{text}", else: "echo '#{text}'"
  end

  describe "the basics" do
    test "runs a command and returns the output", %{root: root} do
      assert {:ok, result} = Command.run_split_streams(root, echo("hello"))

      assert result.reason == :normal
      assert result.code == 0
      assert result.stdout =~ "hello"
    end

    test "returns the duration", %{root: root} do
      assert {:ok, %{duration_ms: duration}} = Command.run_split_streams(root, echo("x"))
      assert is_integer(duration) and duration >= 0
    end

    test "a non-zero exit code is returned as is", %{root: root} do
      line = if windows?(), do: "exit 3", else: "exit 3"

      assert {:ok, %{code: 3, reason: :normal}} = Command.run_split_streams(root, line)
    end

    test "a missing executable returns a named error", %{root: root} do
      assert {:error, {:executable_missing, "program-that-does-not-exist"}} =
               Command.run(root, "program-that-does-not-exist", [])
    end
  end

  describe "SEPARATE stdout and stderr" do
    test "a command writing to both returns both, separately", %{root: root} do
      line =
        if windows?() do
          "echo normal-output & echo error-output 1>&2"
        else
          "echo normal-output; echo error-output 1>&2"
        end

      assert {:ok, result} = Command.run_split_streams(root, line)

      assert result.stdout =~ "normal-output"
      refute result.stdout =~ "error-output"

      assert result.stderr =~ "error-output"
      refute result.stderr =~ "normal-output"
    end

    test "a command writing only to stderr leaves stdout empty", %{root: root} do
      line =
        if windows?(), do: "echo only-error 1>&2", else: "echo only-error 1>&2"

      assert {:ok, result} = Command.run_split_streams(root, line)

      assert String.trim(result.stdout) == ""
      assert result.stderr =~ "only-error"
    end
  end

  describe "stdin from a file" do
    # Copies stdin to stdout byte for byte, with no text API that could convert newlines.
    # On Windows that needs a `.ps1` script with raw streams; on Unix `cat` does it.
    defp copy_stdin(root) do
      if windows?() do
        script = Path.join(root, "copy-#{System.unique_integer([:positive])}.ps1")

        File.write!(script, """
        $in = [Console]::OpenStandardInput()
        $out = [Console]::OpenStandardOutput()
        $in.CopyTo($out)
        $out.Flush()
        """)

        ~s(powershell -NoProfile -ExecutionPolicy Bypass -File "#{String.replace(script, "/", "\\")}")
      else
        "cat"
      end
    end

    # The same copy, also writing a fixed line to stderr, to prove stream separation still
    # holds with stdin from a file.
    defp copy_stdin_with_error(root) do
      if windows?() do
        script = Path.join(root, "copy-error-#{System.unique_integer([:positive])}.ps1")

        File.write!(script, """
        $in = [Console]::OpenStandardInput()
        $out = [Console]::OpenStandardOutput()
        $in.CopyTo($out)
        $out.Flush()
        [Console]::Error.WriteLine('fixed-error')
        """)

        ~s(powershell -NoProfile -ExecutionPolicy Bypass -File "#{String.replace(script, "/", "\\")}")
      else
        "cat; echo fixed-error 1>&2"
      end
    end

    test "text with newlines, quotes, & | backticks and %VAR% reaches stdin INTACT", %{
      root: root
    } do
      content =
        "line one\nline two with \"quotes\"\nwith & and | and `backtick` and %VAR%\nend without newline"

      file = Path.join(root, "input.txt")
      File.write!(file, content)

      line = copy_stdin(root)

      assert {:ok, result} =
               Command.run_split_streams(root, line, stdin: {:file, file})

      assert result.reason == :normal
      assert result.stdout == content, "stdin did not arrive byte for byte equal to the file"
    end

    test "without the stdin option the default stays empty (does not wait for data)", %{
      root: root
    } do
      # Without `< nul` / `< /dev/null` this command would wait for stdin and only return on
      # timeout (reason :timeout, not :normal).
      line = copy_stdin(root)

      assert {:ok, result} = Command.run_split_streams(root, line, timeout: 3_000)

      assert result.reason == :normal
      assert result.stdout == ""
    end

    test "stdout and stderr stay SEPARATE with stdin from a file", %{root: root} do
      content = "input-content"
      file = Path.join(root, "input2.txt")
      File.write!(file, content)

      line = copy_stdin_with_error(root)

      assert {:ok, result} =
               Command.run_split_streams(root, line, stdin: {:file, file})

      assert result.stdout == content
      refute result.stdout =~ "fixed-error"

      assert result.stderr =~ "fixed-error"
      refute result.stderr =~ "input-content"
    end

    test "a missing input file returns a named error", %{root: root} do
      missing = Path.join(root, "does-not-exist.txt")

      assert {:error, {:input_file_missing, ^missing}} =
               Command.run_split_streams(root, echo("x"), stdin: {:file, missing})
    end
  end

  describe "the collector drains what arrives AFTER exit_status" do
    # `Command.collect/5` is public only for this: the defect is a message ORDER in the
    # process mailbox. Building that order by hand makes the test deterministic.
    defp fake_start, do: System.monotonic_time(:millisecond)

    test "a {:data, _} arriving AFTER {:exit_status, _} is not lost" do
      port = make_ref()
      send(self(), {port, {:exit_status, 0}})
      send(self(), {port, {:data, "late-output"}})

      assert {:ok, result} = Command.collect(port, nil, 5_000, fake_start(), [])

      assert result.reason == :normal
      assert result.code == 0
      assert result.stdout == "late-output"
    end

    test "several late chunks arrive complete and IN ORDER" do
      port = make_ref()
      send(self(), {port, {:data, "first-"}})
      send(self(), {port, {:exit_status, 0}})
      send(self(), {port, {:data, "second-"}})
      send(self(), {port, {:data, "third"}})

      assert {:ok, result} = Command.collect(port, nil, 5_000, fake_start(), [])

      assert result.stdout == "first-second-third"
    end

    test "with no late data, the result is still correct" do
      port = make_ref()
      send(self(), {port, {:data, "single"}})
      send(self(), {port, {:exit_status, 0}})

      assert {:ok, result} = Command.collect(port, nil, 5_000, fake_start(), [])

      assert result.stdout == "single"
    end
  end

  describe "under real concurrency the output never disappears" do
    test "git log with an invalid option, 100 times in parallel, never returns empty output", %{
      root: root
    } do
      # `git log --invalid-option` only complains about the OPTION once the repository has a
      # commit; in an empty repo it complains about the missing commit first.
      {_, 0} = System.cmd("git", ["init", "--quiet"], cd: root)
      {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: root)
      {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: root)

      {_, 0} =
        System.cmd("git", ["commit", "--allow-empty", "-m", "initial", "--quiet"], cd: root)

      results =
        1..100
        |> Task.async_stream(
          fn _ -> Command.run_split_streams(root, "git log --invalid-option") end,
          max_concurrency: 24,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      empty =
        Enum.filter(results, fn {:ok, result} ->
          String.trim(result.stdout <> result.stderr) == ""
        end)

      assert empty == [],
             "#{length(empty)} of 100 runs came back with empty output"

      assert Enum.all?(results, fn {:ok, result} ->
               result.stdout <> result.stderr =~ "unrecognized argument"
             end)
    end
  end

  describe "timeout" do
    test "a command exceeding the timeout returns reason :timeout, not :normal", %{root: root} do
      # A timeout is NOT a failed test; the rework ladder treats them differently.
      line = if windows?(), do: "ping -n 30 127.0.0.1", else: "sleep 30"

      assert {:ok, result} = Command.run_split_streams(root, line, timeout: 800)

      assert result.reason == :timeout
      assert result.code == nil, "no exit code: the command never finished"
    end

    test "a fast command does not trigger the timeout", %{root: root} do
      assert {:ok, %{reason: :normal}} =
               Command.run_split_streams(root, echo("fast"), timeout: 10_000)
    end

    test "the default timeout is two minutes" do
      assert Command.default_timeout() == 120_000
    end

    test "a timeout does not lose what was written before the tree was killed" do
      port = make_ref()
      send(self(), {port, {:data, "written-before-timeout"}})

      assert {:ok, result} =
               Command.collect(port, nil, 50, System.monotonic_time(:millisecond), [])

      assert result.reason == :timeout
      assert result.code == nil
      assert result.stdout == "written-before-timeout"
    end
  end

  describe "the process tree — the GRANDCHILD test" do
    test "killing on timeout ALSO kills the child", %{root: root} do
      # The command launches a CHILD that writes its own PID and sleeps. If only the launched
      # process dies, the child stays alive. The child lives in its own script to avoid three
      # levels of nested quoting.
      pidfile = Path.join(root, "grandchild.pid")
      child = Path.join(root, if(windows?(), do: "child.ps1", else: "child.sh"))

      if windows?() do
        File.write!(
          child,
          "$PID | Out-File -Encoding ascii '#{pidfile}'\nStart-Sleep -Seconds 30\n"
        )
      else
        File.write!(child, "#!/bin/sh\necho $$ > \"#{pidfile}\"\nsleep 30\n")
        File.chmod!(child, 0o755)
      end

      line =
        if windows?() do
          ~s(start /b powershell -NoProfile -ExecutionPolicy Bypass -File "#{String.replace(child, "/", "\\")}" & ping -n 30 127.0.0.1)
        else
          ~s(sh "#{child}" & sleep 30)
        end

      assert {:ok, %{reason: :timeout}} = Command.run_split_streams(root, line, timeout: 4_000)

      grandchild = read_pid(pidfile)

      if grandchild do
        # Give taskkill /T a moment to propagate.
        Process.sleep(500)

        refute survived?(grandchild),
               "the grandchild (pid #{grandchild}) survived the timeout: an orphan process."
      else
        flunk("""
        the child never wrote its PID, so this test proved nothing.
        Without the grandchild's PID it would only confirm that the command ended.
        """)
      end
    end

    test "killing a pid that already died is not an error" do
      assert :ok = ProcessTree.kill(999_999)
    end

    test "an invalid pid is refused" do
      assert {:error, :invalid_pid} = ProcessTree.kill(0)
      assert {:error, :invalid_pid} = ProcessTree.kill(-1)
    end

    test "alive? recognizes the runtime's own process" do
      # Otherwise `alive?` always returning false would make the grandchild test pass vacuously.
      my_pid = :os.getpid() |> List.to_string() |> String.to_integer()

      assert ProcessTree.alive?(my_pid)
    end

    test "alive? returns false for a nonexistent pid" do
      refute ProcessTree.alive?(999_998)
    end
  end

  describe "working directory" do
    test "runs in the project root, never in the factory root", %{root: root} do
      mark = "mark-#{System.unique_integer([:positive])}"
      File.write!(Path.join(root, "#{mark}.txt"), "x")

      line = if windows?(), do: "dir /b", else: "ls"

      assert {:ok, result} = Command.run_split_streams(root, line)
      assert result.stdout =~ mark
    end

    test "can run in a project subdirectory", %{root: root} do
      File.write!(Path.join([root, "sub", "inside-sub.txt"]), "x")

      line = if windows?(), do: "dir /b", else: "ls"

      assert {:ok, result} = Command.run_split_streams(root, line, dir: "sub")
      assert result.stdout =~ "inside-sub"
    end
  end

  describe "platform" do
    test "the platform is recognized" do
      assert ProcessTree.platform() in [:windows, :unix]
    end

    test "this run exercised this machine's branch", %{root: root} do
      # Not only detection (which would be tautological): the script the shell read must be
      # this platform's — `.bat` on Windows, `.sh` on Unix.
      expected = if match?({:win32, _}, :os.type()), do: :windows, else: :unix

      assert ProcessTree.platform() == expected,
             "platform detection (#{ProcessTree.platform()}) does not match the OS " <>
               "(#{inspect(:os.type())})"

      {line, extension} =
        if windows?(), do: {"echo %~x0", ".bat"}, else: {~s(echo "$0"), ".sh"}

      assert {:ok, %{code: 0, stdout: stdout}} = Command.run_split_streams(root, line)

      assert String.ends_with?(String.trim(stdout), extension),
             "the script that ran is not this platform's #{extension}: #{inspect(stdout)}"
    end
  end

  describe "the temporary script" do
    test "runs without depending on the file's execute bit", %{root: root} do
      # Proves both halves: the command ran AND the file the shell read was not executable.
      if windows?() do
        # Windows has no execute bit: `cmd /c file.bat` decides by extension.
        assert {:ok, %{code: 0, stdout: stdout}} =
                 Command.run_split_streams(root, echo("no-bit"))

        assert stdout =~ "no-bit"
      else
        line = ~s(if [ -x "$0" ]; then echo with-bit; else echo no-bit; fi)

        assert {:ok, %{code: 0, stdout: "no-bit\n"}} = Command.run_split_streams(root, line)
      end
    end
  end

  # The grandchild SURVIVED if it still runs — a zombie does not. An orphan adopted by a lazy
  # PID 1 stays `<defunct>` for a while and `kill -0` still finds it, but it holds nothing.
  defp survived?(pid), do: ProcessTree.alive?(pid) and not zombie?(pid)

  defp zombie?(pid) do
    if windows?() do
      false
    else
      case System.cmd("ps", ["-o", "stat=", "-p", to_string(pid)], stderr_to_stdout: true) do
        {state, 0} -> String.starts_with?(String.trim(state), "Z")
        _ -> false
      end
    end
  end

  defp read_pid(path) do
    with {:ok, text} <- File.read(path),
         {pid, _} <- text |> String.trim() |> Integer.parse() do
      pid
    else
      _ -> nil
    end
  end
end
