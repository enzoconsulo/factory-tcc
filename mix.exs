defmodule Factory.MixProject do
  use Mix.Project

  def project do
    [
      app: :factory,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: dialyzer()
    ]
  end

  # `:mix` and `:ex_unit` are added to the PLT because the project's own mix tasks and test
  # helpers call into them; without them Dialyzer reports `unknown_function` for real functions.
  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      flags: [:error_handling, :unmatched_returns],
      # Warnings are ignored per file, each with its reason (see `.dialyzer_ignore.exs`),
      # never with a flag that disables a check for the whole project.
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Factory.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    # `verify` ends in `mix test`, which Mix refuses to run from the `dev` environment.
    [
      preferred_envs: [precommit: :test, verify: :test, "test.backup": :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.13"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},

      # Plain HTTP client for `Factory.Provider.MessagesAPI`: the core decides, per request,
      # where to place cache breakpoints and which TTL to ask for, which an SDK would hide.
      {:req, "~> 0.5"},

      # Durable queue: enqueuing a job and changing a task's status happen in the SAME
      # transaction, in the same Postgres as the tasks (see `Factory.Tasks.Transition`).
      {:oban, "~> 2.24"},

      # Quality tools (command-line only, never part of the running system).
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ] ++ local_embedder_deps()
  end

  # `Factory.Embedder.Local` needs Bumblebee + Nx + EXLA (over 1 GB). Mix cannot mark an
  # application's own dependency as optional, so the gate is this function: without
  # `FACTORY_EMBEDDER_LOCAL=1` the list is empty and `mix deps.get` never fetches them.
  # The E2 milestone test asserts they stay unloadable by default.
  defp local_embedder_deps do
    if System.get_env("FACTORY_EMBEDDER_LOCAL") == "1" do
      [
        {:bumblebee, "~> 0.6"},
        {:nx, "~> 0.9"},
        {:exla, "~> 0.9"}
      ]
    else
      []
    end
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],

      # Backup/restore runs alone: `pg_restore --clean` drops and recreates tables of the
      # shared test database, which would break concurrent tests. `test/test_helper.exs`
      # excludes `:needs_pg_dump` by default; `--only` overrides that for this alias.
      "test.backup": [
        "ecto.create --quiet",
        "ecto.migrate --quiet",
        "test --only needs_pg_dump"
      ],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind factory", "esbuild factory"],
      "assets.deploy": [
        "tailwind factory --minify",
        "esbuild factory --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],

      # Fast local check, cheapest stage first; the first failure stops the rest.
      # Dialyzer is left out (its first run builds the PLT and takes minutes); it runs as a
      # separate stage of `mix factory.ci`.
      verify: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test"
      ]
    ]
  end
end
