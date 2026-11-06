defmodule Factory.LocalDb do
  @moduledoc """
  Starts, stops and inspects the local PostgreSQL cluster the application uses in development,
  so the whole system runs from this repository with one command.

      mix factory.db init     # creates the cluster once (initdb)
      mix factory.db start    # starts it and waits until it accepts connections
      mix factory.db status
      mix factory.db stop

  Binaries come from `config :factory, :pg_bin` (the same setting `Factory.Backup` uses) and the
  data directory from `config :factory, :pg_data`. The server is not a Windows service on
  purpose: it runs only while the system is being used.

  Every function takes `:cmd`, `:dir?` and `:data`, so the decisions are testable without a
  real server.
  """

  alias Factory.Backup

  @host "127.0.0.1"
  @port "5432"
  @default_data "C:/pgsql/data"

  @type opts :: keyword()

  @doc "The cluster's data directory."
  @spec data_dir(opts()) :: Path.t()
  def data_dir(opts \\ []) do
    Keyword.get_lazy(opts, :data, fn ->
      Application.get_env(:factory, :pg_data) || @default_data
    end)
  end

  @doc "`:up` when the server accepts connections on 127.0.0.1:5432, `:down` otherwise."
  @spec status(opts()) :: :up | :down
  def status(opts \\ []) do
    case cmd(opts, "pg_isready", ["-h", @host, "-p", @port]) do
      {_, 0} -> :up
      _ -> :down
    end
  end

  @doc "Creates the cluster with the `postgres` user and local `trust` authentication."
  @spec init(opts()) :: {:ok, :created | :exists} | {:error, term()}
  def init(opts \\ []) do
    data = data_dir(opts)

    if dir?(opts, data) do
      {:ok, :exists}
    else
      args = ["-D", data, "-U", "postgres", "-A", "trust", "-E", "UTF8"]

      case cmd(opts, "initdb", args) do
        {_, 0} -> {:ok, :created}
        {out, code} -> {:error, {:initdb_failed, code, out}}
      end
    end
  end

  @doc "Starts the server and waits until it accepts connections. Idempotent."
  @spec start(opts()) :: {:ok, :started | :already_up} | {:error, term()}
  def start(opts \\ []) do
    data = data_dir(opts)

    cond do
      status(opts) == :up ->
        {:ok, :already_up}

      not dir?(opts, data) ->
        {:error, {:no_cluster, data}}

      true ->
        log = Path.join(data, "server.log")

        case cmd(opts, "pg_ctl", ["-D", data, "-l", log, "-w", "start"]) do
          {_, 0} -> {:ok, :started}
          {out, code} -> {:error, {:start_failed, code, out}}
        end
    end
  end

  @doc "Stops the server (fast mode: open sessions are closed). Idempotent."
  @spec stop(opts()) :: {:ok, :stopped | :already_down} | {:error, term()}
  def stop(opts \\ []) do
    if status(opts) == :down do
      {:ok, :already_down}
    else
      case cmd(opts, "pg_ctl", ["-D", data_dir(opts), "-m", "fast", "-w", "stop"]) do
        {_, 0} -> {:ok, :stopped}
        {out, code} -> {:error, {:stop_failed, code, out}}
      end
    end
  end

  defp cmd(opts, program, args) do
    run = Keyword.get(opts, :cmd, &System.cmd/3)
    exe = Backup.executable(program)

    try do
      run.(exe, args, stderr_to_stdout: true)
    rescue
      error in ErlangError -> {"#{exe}: #{inspect(error.original)}", 127}
    end
  end

  defp dir?(opts, path), do: Keyword.get(opts, :dir?, &File.dir?/1).(path)
end
