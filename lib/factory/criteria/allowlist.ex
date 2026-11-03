defmodule Factory.Criteria.Allowlist do
  @moduledoc """
  May this command run unsupervised? **An allowlist, never a denylist.**

  A denylist fails open when it is incomplete; an allowlist fails closed. A binary is allowed
  when it **verifies** (runs tests, compiles, checks files) and does not publish, install or
  delete. `git` is allowed only in read-only mode (`status`, `log`, `diff`, ...); `push`,
  `reset` and `clean` are refused by subcommand.

  `npx` is deliberately excluded: it downloads and runs code that is not in the project, which
  would turn any allowed binary into a door to any other. A criterion that needs an external
  tool must declare it as a project dependency and call it through a script.

  The threat model is a badly specified criterion, not a malicious one: criteria are written by
  the planner and the builder cannot change them. That is why `mix` and `cargo` are allowed even
  though they run project code — running the project's code is the point.
  """

  @typedoc "Why the command was refused."
  @type reason ::
          :no_command
          | :binary_not_allowed
          | :chaining_forbidden
          | :git_not_read_only

  @binaries ~w[
    mix elixir iex
    npm pnpm yarn node
    python python3 pytest ruff mypy
    go cargo dotnet mvn gradle
    tsc eslint prettier vitest jest
    ls cat grep rg find test
    git
  ]

  @git_read_only ~w[status log show diff ls-files rev-parse describe cat-file]

  # Chaining, redirection and substitution. A criterion needs ONE command, not a script: a
  # script belongs in a versioned project alias that the criterion calls.
  @dangerous ~r/[;&|`$><\n\r]|\$\(/

  @doc "The allowed binaries, sorted."
  @spec binaries() :: [String.t()]
  def binaries, do: Enum.sort(@binaries)

  @doc "The `git` subcommands that only READ."
  @spec git_read_only() :: [String.t()]
  def git_read_only, do: Enum.sort(@git_read_only)

  @doc """
  Checks the command declared in a criterion.

  Returns `{:ok, argv}` already split into program and arguments, ready for
  `Factory.Tools.Command.run/4` (which uses no shell), so what was checked is exactly what runs.

  ## Examples

      iex> Factory.Criteria.Allowlist.check("mix test")
      {:ok, ["mix", "test"]}

      iex> Factory.Criteria.Allowlist.check("curl http://example")
      {:refused, :binary_not_allowed}

      iex> Factory.Criteria.Allowlist.check("mix test && git push")
      {:refused, :chaining_forbidden}
  """
  @spec check(String.t() | nil) :: {:ok, [String.t()]} | {:refused, reason()}
  def check(command) do
    raw = command |> to_string() |> String.trim()

    cond do
      raw == "" -> {:refused, :no_command}
      Regex.match?(@dangerous, raw) -> {:refused, :chaining_forbidden}
      true -> check_binary(String.split(raw, ~r/\s+/))
    end
  end

  defp check_binary([program | args] = argv) do
    binary = normalize(program)

    cond do
      binary not in @binaries -> {:refused, :binary_not_allowed}
      binary == "git" and not git_read_only?(args) -> {:refused, :git_not_read_only}
      true -> {:ok, argv}
    end
  end

  defp git_read_only?([subcommand | _]), do: String.downcase(subcommand) in @git_read_only
  defp git_read_only?([]), do: false

  # `.exe`, `.cmd` and `.bat` are the same tool under its Windows name.
  defp normalize(program) do
    program |> String.downcase() |> String.replace(~r/\.(exe|cmd|bat)$/, "")
  end
end
