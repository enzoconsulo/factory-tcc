defmodule Factory.Tools.Command do
  @moduledoc """
  Runs an external command in the project directory, with a timeout that kills the whole
  process TREE.

  Guarantees:

  1. The timeout kills the tree, not only the launched process (`Factory.Tools.ProcessTree`).
  2. `run_split_streams/3` returns `stdout` and `stderr` SEPARATELY, so failure
     classification can tell "the command is broken" from "the delivery failed".
  3. The stop reason is explicit: `:normal`, `:timeout` or `:cancelled`. A timeout is not a
     failed test, and an exit status alone does not say that.

  It uses `Port` with `:spawn_executable` rather than `System.cmd/3`, because only a port
  exposes the OS pid needed to kill the tree.
  """

  require Logger

  alias Factory.Tools.Confinement
  alias Factory.Tools.ProcessTree

  @default_timeout 120_000

  @typedoc "Why the command ended."
  @type reason :: :normal | :timeout | :cancelled

  @type result :: %{
          code: integer() | nil,
          stdout: String.t(),
          stderr: String.t(),
          duration_ms: non_neg_integer(),
          reason: reason()
        }

  @doc "The default timeout, in milliseconds (two minutes)."
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout

  @doc """
  Runs `program` with `args` inside `root`.

  The working directory is ALWAYS the project root resolved by the confinement, never the
  factory root.
  """
  @spec run(Path.t(), String.t(), [String.t()], keyword()) ::
          {:ok, result()} | {:error, term()}
  def run(root, program, args \\ [], opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, dir} <- Confinement.resolve(root, Keyword.get(opts, :dir, ".")),
         {:ok, executable} <- locate(program) do
      start = System.monotonic_time(:millisecond)

      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :hide,
          :stderr_to_stdout,
          args: args,
          cd: dir
        ])

      pid = os_pid(port)
      collect(port, pid, timeout, start, [])
    end
  end

  @typedoc """
  Where the command's `stdin` comes from. `:empty` (the default) keeps `< nul` /
  `< /dev/null`. `{:file, path}` redirects from that file, so text with newlines, quotes,
  `&`, `|`, backticks or `%VAR%` arrives intact without ever being interpolated.
  """
  @type stdin :: :empty | {:file, Path.t()}

  @doc """
  Runs a command line capturing `stdout` and `stderr` in SEPARATE streams.

  OTP ports do not expose `stderr` separately, so the line runs through a temporary shell
  script that redirects each stream to its own temporary file. The `stdin:` option feeds
  `stdin` from a file (`{:file, path}`); the content is never interpolated into a command line.
  """
  @spec run_split_streams(Path.t(), String.t(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def run_split_streams(root, line, opts \\ []) do
    stdin = Keyword.get(opts, :stdin, :empty)

    with {:ok, dir} <- Confinement.resolve(root, Keyword.get(opts, :dir, ".")),
         :ok <- validate_stdin(stdin) do
      mark = System.unique_integer([:positive])
      out = Path.join(System.tmp_dir!(), "cmd-out-#{mark}")
      err = Path.join(System.tmp_dir!(), "cmd-err-#{mark}")
      script = write_script(mark, line, out, err, stdin)

      {program, prefix} = shell()

      response =
        run_raw(dir, program, prefix ++ [for_shell(script)], opts)

      remove(script)

      case response do
        {:ok, partial} ->
          {:ok, %{partial | stdout: read_and_remove(out), stderr: read_and_remove(err)}}

        other ->
          remove(out)
          remove(err)
          other
      end
    end
  end

  defp validate_stdin(:empty), do: :ok

  defp validate_stdin({:file, path}) do
    if File.regular?(path) do
      :ok
    else
      {:error, {:input_file_missing, path}}
    end
  end

  # A temporary script rather than the line passed straight to the shell: `Port.open` with
  # `args:` quotes any argument containing a space, and `cmd` chokes on nested quotes. In a
  # script file the quotes belong to the file and nobody re-quotes them.
  #
  # The grouping (`( ... )` in cmd, `{ ... ; }` in sh) makes the redirections apply to the
  # whole compound line, not only to its last command. `stdin` comes from the null device by
  # default: the factory is not interactive, and a process waiting for input would stall
  # (and pollute `stderr` with warnings).
  defp write_script(mark, line, out, err, stdin) do
    {extension, content} =
      case :os.type() do
        {:win32, _} ->
          source = stdin_source(stdin, "nul")

          {".bat",
           "@echo off\r\n(#{line}) < #{source} > \"#{for_shell(out)}\" " <>
             "2> \"#{for_shell(err)}\"\r\n"}

        _ ->
          source = stdin_source(stdin, "/dev/null")
          {".sh", "#!/bin/sh\n{ #{line} ; } < #{source} > \"#{out}\" 2> \"#{err}\"\n"}
      end

    path = Path.join(System.tmp_dir!(), "factory-cmd-#{mark}#{extension}")
    File.write!(path, content)
    path
  end

  defp stdin_source(:empty, null_device), do: null_device
  defp stdin_source({:file, path}, _null_device), do: "\"#{for_shell(path)}\""

  defp run_raw(dir, program, args, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, executable} <- locate(program) do
      start = System.monotonic_time(:millisecond)

      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :hide,
          args: args,
          cd: dir
        ])

      collect(port, os_pid(port), timeout, start, [])
    end
  end

  # The collection loop. The `after` makes the timeout belong to the system, not the command:
  # a stuck command never sends `exit_status`.
  #
  # Public (but `@doc false`) only so the message-ordering behaviour can be tested by building
  # the mailbox by hand.
  @doc false
  @spec collect(port() | reference(), integer() | nil, non_neg_integer(), integer(), [binary()]) ::
          {:ok, result()}
  def collect(port, pid, timeout, start, chunks) do
    receive do
      {^port, {:data, data}} ->
        collect(port, pid, timeout, start, [data | chunks])

      {^port, {:exit_status, code}} ->
        {:ok, build(code, drain(port, chunks), start, :normal)}
    after
      timeout ->
        chunks = drain(port, chunks)
        kill(port, pid)
        {:ok, build(nil, chunks, start, :timeout)}
    end
  end

  # On Windows the port driver does not guarantee that the last data chunk arrives before
  # `exit_status`; under load stdout came back empty. This short window always ends.
  @drain_window_ms 50

  defp drain(port, chunks) do
    receive do
      {^port, {:data, data}} ->
        drain(port, [data | chunks])
    after
      @drain_window_ms -> chunks
    end
  end

  defp kill(port, pid) do
    # `ProcessTree.kill/1` already logs its own failure; the port closes either way.
    _ = if pid, do: ProcessTree.kill(pid)

    # Close the port only AFTER killing the tree, or the OS pid would be lost.
    if Port.info(port), do: Port.close(port)

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp build(code, chunks, start, reason) do
    %{
      code: code,
      stdout: chunks |> Enum.reverse() |> IO.iodata_to_binary(),
      stderr: "",
      duration_ms: System.monotonic_time(:millisecond) - start,
      reason: reason
    }
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp locate(program) do
    case System.find_executable(program) do
      nil -> {:error, {:executable_missing, program}}
      path -> {:ok, path}
    end
  end

  # On Unix the script is passed as a FILE for `sh` to read (`sh <file>`), not run via `-c`:
  # the temporary file has no execute bit, and `sh -c <file>` would exit with 126.
  defp shell do
    case :os.type() do
      {:win32, _} -> {"cmd", ["/c"]}
      _ -> {"sh", []}
    end
  end

  # Windows `cmd` rejects `>` to a path with forward slashes, and `Path.join` produces mixed
  # separators.
  defp for_shell(path) do
    case :os.type() do
      {:win32, _} -> String.replace(path, "/", "\\")
      _ -> path
    end
  end

  # Best effort, but never silent: a leaked temporary file shows up only when the disk fills.
  # The single `:ok` return lets callers discard it without a Dialyzer warning.
  @spec remove(Path.t()) :: :ok
  defp remove(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("could not remove temporary file #{path}: #{inspect(reason)}")
    end
  end

  defp read_and_remove(path) do
    content =
      case File.read(path) do
        {:ok, text} -> text
        _ -> ""
      end

    remove(path)
    content
  end
end
