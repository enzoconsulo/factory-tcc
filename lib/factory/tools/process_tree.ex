defmodule Factory.Tools.ProcessTree do
  @moduledoc """
  Kills an external process AND ITS CHILDREN.

  Killing the launched process does not kill its children, and the factory rarely launches
  the process that matters: it launches `mix`, which launches `erl`, or `cmd`, which launches
  `npm`, which launches `node`. Killing only the first leaves orphans holding memory.

  | platform | how | why |
  |---|---|---|
  | Windows | `taskkill /PID <pid> /T /F` | `/T` is the tree |
  | Unix | `kill -TERM -<pgid>`, then `-KILL` | a signal to the GROUP (negative pid) reaches the children |
  """

  require Logger

  @doc "The platform, so tests know which branch they exercise."
  @spec platform() :: :windows | :unix
  def platform do
    case :os.type() do
      {:win32, _} -> :windows
      _ -> :unix
    end
  end

  @doc """
  Kills the process and the whole tree below it.

  Returns `:ok` even when the process already died on its own: that is the normal race
  between a timeout and the end of the command.
  """
  @spec kill(pos_integer()) :: :ok | {:error, term()}
  def kill(pid) when is_integer(pid) and pid > 0 do
    case platform() do
      :windows -> kill_windows(pid)
      :unix -> kill_unix(pid)
    end
  end

  def kill(_pid), do: {:error, :invalid_pid}

  defp kill_windows(pid) do
    case System.cmd("taskkill", ["/PID", to_string(pid), "/T", "/F"], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      # 128 is "process not found": it already died.
      {_output, 128} ->
        :ok

      {output, code} ->
        Logger.warning("taskkill of pid #{pid} returned #{code}: #{String.trim(output)}")
        {:error, {:taskkill, code}}
    end
  rescue
    error -> {:error, {:taskkill_unavailable, error}}
  end

  defp kill_unix(pid) do
    # The signal goes to the GROUP (negative pid), otherwise only the leader dies.
    _ = System.cmd("kill", ["-TERM", "--", "-#{pid}"], stderr_to_stdout: true)
    Process.sleep(100)
    _ = System.cmd("kill", ["-KILL", "--", "-#{pid}"], stderr_to_stdout: true)
    :ok
  rescue
    error -> {:error, {:kill_unavailable, error}}
  end

  @doc "Tells whether an OS process is still alive. Lets tests check the grandchild."
  @spec alive?(pos_integer()) :: boolean()
  def alive?(pid) when is_integer(pid) and pid > 0 do
    case platform() do
      :windows -> alive_windows?(pid)
      :unix -> match?({_, 0}, System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true))
    end
  rescue
    _ -> false
  end

  def alive?(_pid), do: false

  defp alive_windows?(pid) do
    {output, _code} =
      System.cmd("tasklist", ["/FI", "PID eq #{pid}", "/NH"], stderr_to_stdout: true)

    # `tasklist` exits 0 even when nothing matches, so the verdict is the PID in the output.
    String.contains?(output, to_string(pid))
  end
end
