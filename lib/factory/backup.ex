defmodule Factory.Backup do
  @moduledoc """
  Database dump and restore. With the system state in the database, not losing work requires
  dumps.

  The location of `pg_dump`/`pg_restore` comes from configuration, never from the PATH: a
  client binary of the wrong version produces a dump that looks valid but fails at restore.

      config :factory, :pg_bin, "C:/pgsql/18/bin"
  """

  require Logger

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @default_backup_dir "priv/backups"

  @doc "The directory where dumps are written. Kept out of git."
  @spec directory() :: Path.t()
  def directory do
    # `||` rather than `get_env/3`'s default: the key may be present with value `nil`.
    Application.get_env(:factory, :backup_dir) || @default_backup_dir
  end

  @doc "The path of a PostgreSQL executable, resolved from configuration."
  @spec executable(String.t()) :: Path.t()
  def executable(name) do
    case Application.get_env(:factory, :pg_bin) do
      nil -> name
      bin -> Path.join(bin, name)
    end
  end

  @doc """
  Whether the configured `pg_dump` is actually available, so tests can skip with a clear
  message on a machine without PostgreSQL.
  """
  @spec available?() :: boolean()
  def available? do
    case run(executable("pg_dump"), ["--version"]) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Writes a dump to `<directory>/YYYYMMDD-HHMMSS.dump` in custom format, which is what
  `pg_restore --clean --if-exists` consumes.
  """
  @spec dump(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def dump(opts \\ []) do
    dest = Keyword.get_lazy(opts, :dest, &timestamped_path/0)
    conn = connection(opts)

    File.mkdir_p!(Path.dirname(dest))

    args =
      connection_args(conn) ++
        ["--format=custom", "--file=#{dest}", conn[:database]]

    case run(executable("pg_dump"), args) do
      {:ok, _output} -> {:ok, dest}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Restores a dump over the database, dropping whatever collides. `--clean --if-exists`
  makes the restore repeatable.
  """
  @spec restore(Path.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def restore(file, opts \\ []) do
    if File.exists?(file) do
      conn = connection(opts)

      args =
        connection_args(conn) ++
          ["--clean", "--if-exists", "--dbname=#{conn[:database]}", file]

      case run(executable("pg_restore"), args) do
        {:ok, _output} ->
          warn(disconnect_all())
          {:ok, file}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, {:dump_missing, file}}
    end
  end

  # `--clean` drops and recreates types, which get new oids; Postgrex caches oids per
  # connection, so live connections would fail with `cache lookup failed for type`. Dropping
  # every connection forces them to reconnect. The Ecto sandbox pool does not support
  # `disconnect_all` (it crashes its manager), so under the sandbox the caller restarts the
  # Repo instead.
  defp disconnect_all do
    repo = Application.get_env(:factory, :backup_repo, Factory.Repo)
    pool = Application.get_env(:factory, repo, [])[:pool]

    cond do
      pool == Sandbox -> {:error, :sandbox_restart_repo}
      is_nil(Process.whereis(repo)) -> {:error, :repo_stopped}
      true -> SQL.disconnect_all(repo, 0)
    end
  end

  # A stopped Repo has no connections to drop; any other failure must be reported, because
  # the application would keep running with stale oids.
  defp warn(:ok), do: :ok
  defp warn({:error, :repo_stopped}), do: :ok

  defp warn({:error, reason}) do
    Logger.warning("""
    database restored, but connections were NOT dropped (#{inspect(reason)}).

    They still hold the type oids from before the restore, and the next query touching a
    custom type will fail with `cache lookup failed for type`. Restart the Repo before
    continuing.
    """)

    :ok
  end

  @doc "The existing dumps, newest first."
  @spec list() :: [Path.t()]
  def list do
    case File.ls(directory()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".dump"))
        |> Enum.sort(:desc)
        |> Enum.map(&Path.join(directory(), &1))

      _ ->
        []
    end
  end

  defp timestamped_path do
    stamp =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.to_string()
      |> String.replace(["-", ":"], "")
      |> String.replace(" ", "-")
      |> String.slice(0, 15)

    Path.join(directory(), "#{String.slice(stamp, 0, 8)}-#{String.slice(stamp, 9, 6)}.dump")
  end

  defp connection(opts) do
    default = Application.get_env(:factory, Factory.Repo, [])

    [
      hostname: Keyword.get(opts, :hostname, default[:hostname] || "127.0.0.1"),
      port: Keyword.get(opts, :port, default[:port] || 5432),
      username: Keyword.get(opts, :username, default[:username] || "postgres"),
      database: Keyword.get(opts, :database, default[:database])
    ]
  end

  defp connection_args(conn) do
    [
      "--host=#{conn[:hostname]}",
      "--port=#{conn[:port]}",
      "--username=#{conn[:username]}",
      "--no-password"
    ]
  end

  # The exit code decides, never stderr text: `pg_dump` writes warnings on success.
  defp run(program, args) do
    {output, code} = System.cmd(program, args, stderr_to_stdout: true)

    if code == 0, do: {:ok, output}, else: {:error, {:command_failed, code, output}}
  rescue
    error in ErlangError -> {:error, {:executable_missing, program, error.original}}
  end
end
