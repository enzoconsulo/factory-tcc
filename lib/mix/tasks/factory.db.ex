defmodule Mix.Tasks.Factory.Db do
  @shortdoc "Starts, stops or creates the local PostgreSQL cluster"

  @moduledoc """
  Manages the local PostgreSQL cluster used in development (see `Factory.LocalDb`).

      mix factory.db start    # before mix setup / mix phx.server
      mix factory.db status
      mix factory.db stop
      mix factory.db init     # once, on a new machine

  Paths come from `FACTORY_PG_BIN` (default `C:/pgsql/18/bin`) and `FACTORY_PG_DATA`
  (default `C:/pgsql/data`).
  """

  use Mix.Task

  alias Factory.LocalDb

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    case args do
      ["start"] -> report(LocalDb.start())
      ["stop"] -> report(LocalDb.stop())
      ["init"] -> report(LocalDb.init())
      [] -> Mix.shell().info("postgres: #{LocalDb.status()}")
      ["status"] -> Mix.shell().info("postgres: #{LocalDb.status()}")
      _ -> Mix.raise("usage: mix factory.db start | stop | status | init")
    end
  end

  defp report({:ok, :started}), do: info("postgres started on 127.0.0.1:5432")
  defp report({:ok, :already_up}), do: info("postgres was already running")
  defp report({:ok, :stopped}), do: info("postgres stopped")
  defp report({:ok, :already_down}), do: info("postgres was not running")
  defp report({:ok, :created}), do: info("cluster created at #{LocalDb.data_dir()}")
  defp report({:ok, :exists}), do: info("cluster already exists at #{LocalDb.data_dir()}")

  defp report({:error, {:no_cluster, dir}}),
    do: Mix.raise("no cluster at #{dir}. Create it once with `mix factory.db init`.")

  defp report({:error, {_, code, out}}),
    do: Mix.raise("postgres command failed (exit #{code}):\n#{out}")

  defp info(message), do: Mix.shell().info(message)
end
