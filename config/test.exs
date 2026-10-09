import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
# 127.0.0.1 rather than "localhost": the cluster listens on IPv4 only, so this skips a name
# lookup and an IPv6 attempt that always fails first. Authentication is `trust`; the password
# is ignored.
config :factory, Factory.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1",
  port: 5432,
  database: "factory_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :factory, FactoryWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "7KeJJIn0td4+fRlWULIY1+t2BVIdrcymaziDuY6z7p14Vei65brRmaxzW6tR9j6N",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Every Req request in the test suite goes to `Factory.NoNetwork`, a Plug that raises: a request
# reaching it is one a test forgot to stub. A config-level Plug is used instead of
# `Req.Test.stub/2` because stubs are per process and the suite runs `async: true`.
# The E2 milestone test relies on this guarantee.
config :req, default_options: [plug: Factory.NoNetwork]
