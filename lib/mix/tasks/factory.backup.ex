defmodule Mix.Tasks.Factory.Backup do
  @shortdoc "Writes a database dump to priv/backups/"

  @moduledoc """
  Writes a database dump in custom format and prints its path.

      mix factory.backup
      mix factory.backup --dest path/to/file.dump

  The `pg_dump` location comes from `config :factory, :pg_bin`, never from the PATH (see
  `Factory.Backup`).
  """

  use Mix.Task

  alias Factory.Backup

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    {opts, _} = OptionParser.parse!(args, strict: [dest: :string])

    case Backup.dump(opts) do
      {:ok, path} ->
        size = File.stat!(path).size
        Mix.shell().info("dump written: #{path} (#{size} bytes)")

      {:error, {:executable_missing, program, _}} ->
        Mix.raise("""
        could not find `pg_dump` at `#{program}`.

        Configure the PostgreSQL binaries directory:

            config :factory, :pg_bin, "C:/pgsql/18/bin"
        """)

      {:error, reason} ->
        Mix.raise("backup failed: #{inspect(reason)}")
    end
  end
end
