# Tests tagged `:needs_pg_dump` (test/mix/backup_test.exs) are always excluded from the default
# `mix test`: they run `pg_restore --clean` against the shared test database, which breaks the
# type-oid cache of connections used by concurrent tests. `mix test.backup` runs them alone.
ExUnit.start(exclude: [:needs_pg_dump])

unless Factory.Backup.available?() do
  IO.puts("""

  WARNING: `pg_dump` not found at #{Factory.Backup.executable("pg_dump")}.
  `mix test.backup` will fail — the backup cycle cannot be exercised on this machine.
  Configure `config :factory, :pg_bin` to run it.
  """)
end

Ecto.Adapters.SQL.Sandbox.mode(Factory.Repo, :manual)
