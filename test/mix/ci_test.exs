defmodule Factory.CITest do
  @moduledoc """
  Locks the battery rules: ORDER, stopping at the first error, and skipping `types` in fast
  mode. No real stage runs: the runner is injected.
  """

  use ExUnit.Case, async: true

  alias Factory.CI

  defp stage(name, opts \\ []) do
    %{
      name: name,
      command: "mix #{name}",
      fast: Keyword.get(opts, :fast, true),
      description: ""
    }
  end

  # Runs everything successfully and records who was called, in order.
  defp recorder(owner) do
    fn stage ->
      send(owner, {:ran, stage.name})
      {:ok, 0, ""}
    end
  end

  defp called do
    Stream.repeatedly(fn ->
      receive do
        {:ran, name} -> name
      after
        0 -> :end
      end
    end)
    |> Enum.take_while(&(&1 != :end))
  end

  describe "order and success" do
    test "runs the stages in declared order and returns :ok" do
      stages = [stage("format"), stage("compile"), stage("lint")]

      {outcome, results} = CI.run(stages, runner: recorder(self()))

      assert outcome == :ok
      assert called() == ["format", "compile", "lint"]
      assert Enum.map(results, & &1.outcome) == [:ok, :ok, :ok]
      assert Enum.all?(results, &is_integer(&1.duration_ms))
    end

    test "an empty list passes" do
      assert {:ok, []} = CI.run([], runner: recorder(self()))
    end
  end

  describe "a failing stage stops the following ones" do
    test "stops at the first error and returns :error" do
      stages = [
        stage("format"),
        stage("compile"),
        stage("lint"),
        stage("test")
      ]

      owner = self()

      runner = fn stage ->
        send(owner, {:ran, stage.name})
        if stage.name == "compile", do: {:error, 1, "broke"}, else: {:ok, 0, ""}
      end

      {outcome, results} = CI.run(stages, runner: runner)

      assert outcome == :error

      # The two following stages were never called: this is the rule that matters.
      assert called() == ["format", "compile"]

      assert Enum.map(results, & &1.outcome) == [:ok, :error]
      assert length(results) == 2, "a stage not reached must not appear in the report"
    end

    test "the result keeps the exit code of the stage that broke" do
      runner = fn _ -> {:error, 42, "output"} end

      {:error, [result]} = CI.run([stage("format")], runner: runner)

      assert result.code == 42
      assert result.stage.name == "format"
    end

    test "failing at the LAST stage also returns :error" do
      runner = fn stage ->
        if stage.name == "test", do: {:error, 1, ""}, else: {:ok, 0, ""}
      end

      {outcome, results} = CI.run([stage("lint"), stage("test")], runner: runner)

      assert outcome == :error
      assert Enum.map(results, & &1.outcome) == [:ok, :error]
    end
  end

  describe "fast mode" do
    test "skips the non-fast stage and runs the others" do
      stages = [
        stage("format"),
        stage("compile"),
        stage("lint"),
        stage("test"),
        stage("types", fast: false)
      ]

      {outcome, _results} = CI.run(stages, fast: true, runner: recorder(self()))

      # Read once: `called/0` drains the mailbox, so a second call would return `[]` and any
      # `refute ... in called()` would pass vacuously.
      ran = called()

      assert outcome == :ok
      assert ran == ["format", "compile", "lint", "test"]
      refute "types" in ran
    end

    test "the skipped stage APPEARS in the report, marked" do
      stages = [stage("test"), stage("types", fast: false)]

      {:ok, results} = CI.run(stages, fast: true, runner: recorder(self()))

      assert Enum.map(results, & &1.outcome) == [:ok, :skipped]
      assert Enum.map(results, & &1.stage.name) == ["test", "types"]
    end

    test "without --fast, the non-fast stage runs" do
      stages = [stage("types", fast: false)]

      {:ok, results} = CI.run(stages, runner: recorder(self()))

      assert called() == ["types"]
      assert Enum.map(results, & &1.outcome) == [:ok]
    end
  end

  describe "_management/ci.json" do
    test "is read and declares the six stages, in order, with the real commands" do
      {:ok, stages} = CI.stages()

      assert Enum.map(stages, & &1.name) == ~w[format compile lint tests types backup]

      assert Enum.map(stages, & &1.command) == [
               "mix format --check-formatted",
               "mix compile --warnings-as-errors",
               "mix credo --strict",
               "mix test",
               "mix dialyzer",
               "mix test.backup"
             ]
    end

    test "only the `types` stage is left out of fast mode" do
      {:ok, stages} = CI.stages()

      assert Enum.filter(stages, &(not &1.fast)) |> Enum.map(& &1.name) == ["types"]
    end

    test "every stage declares a non-empty description" do
      {:ok, stages} = CI.stages()
      assert Enum.all?(stages, &(String.trim(&1.description) != ""))
    end

    test "a missing file returns a named error, not an exception" do
      assert {:error, {:ci_json_missing, "does/not/exist.json"}} =
               CI.stages(path: "does/not/exist.json")
    end

    test "the `tests` stage command is the one the factory runs on every verification" do
      # Tasks copy their `verify:` command from here instead of writing it from memory.
      {:ok, stages} = CI.stages()
      test_stage = Enum.find(stages, &(&1.name == "tests"))

      assert test_stage.command == "mix test"
    end
  end
end
