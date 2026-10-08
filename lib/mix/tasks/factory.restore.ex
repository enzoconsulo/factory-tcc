defmodule Mix.Tasks.Factory.Restore do
  @shortdoc "Restores the database from a dump"

  @moduledoc """
  Restores the database from a dump written by `mix factory.backup`.

      mix factory.restore priv/backups/20260828-120000.dump
      mix factory.restore --latest

  Uses `pg_restore --clean --if-exists`, so restoring is repeatable.
  """

  use Mix.Task

  alias Factory.Backup

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    {opts, rest} = OptionParser.parse!(args, strict: [latest: :boolean])

    case choose(opts, rest) do
      {:ok, file} -> restore(file)
      {:error, message} -> Mix.raise(message)
    end
  end

  defp choose(opts, rest) do
    cond do
      rest != [] ->
        {:ok, hd(rest)}

      Keyword.get(opts, :latest, false) ->
        case Backup.list() do
          [newest | _] -> {:ok, newest}
          [] -> {:error, "there are no dumps in #{Backup.directory()}"}
        end

      true ->
        {:error, "usage: mix factory.restore <file.dump> | --latest"}
    end
  end

  defp restore(file) do
    case Backup.restore(file) do
      {:ok, path} ->
        Mix.shell().info("database restored from #{path}")

      {:error, {:dump_missing, path}} ->
        Mix.raise("dump not found: #{path}")

      {:error, reason} ->
        Mix.raise("restore failed: #{inspect(reason)}")
    end
  end
end
