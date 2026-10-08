defmodule Factory.Rework.DiagnosisTest do
  @moduledoc """
  `diagnose/2` holds the whole rework judgement and is pure, so it is tested exhaustively. The
  most valuable block is PRECEDENCE: a real failure can carry a blocker, a conformance verdict
  and findings at once, and picking the wrong nature costs a whole cycle of the wrong size.
  """

  use ExUnit.Case, async: true

  alias Factory.Rework.Diagnosis
  alias Factory.Rework.Policy

  doctest Factory.Rework.Policy

  defp finding(severity, attrs \\ []) do
    default = %{severity: severity, file: "lib/a.ex", line: 10, problem: "something"}
    Map.merge(default, Map.new(attrs))
  end

  describe "the four natures, one test each" do
    test "blocker: the builder declared it cannot proceed" do
      policy = Diagnosis.diagnose(%{blocker: "the Postgres credential is missing"})

      assert policy.nature == :blocker
      assert policy.scope == :whole_task
      assert policy.width == :medium
      assert hd(policy.focus) =~ "DECLARED BLOCKER: the Postgres credential is missing"
    end

    test "conformance: delivered something else" do
      policy =
        Diagnosis.diagnose(%{
          conformance: {:nonconforming, "implemented search, the task asked for sorting"},
          goal: "sort the player list"
        })

      assert policy.nature == :conformance
      assert policy.scope == :whole_task
      assert policy.width == :wide
    end

    test "functional: an executable criterion failed" do
      policy = Diagnosis.diagnose(%{failed_criteria: ["the suite passes"]})

      assert policy.nature == :functional
      assert policy.scope == :whole_task
      assert policy.width == :medium
    end

    test "localized: a finding with a named file and line" do
      policy = Diagnosis.diagnose(%{findings: [finding(:low)]})

      assert policy.nature == :localized
      assert policy.scope == {:files, ["lib/a.ex"]}
      assert policy.width == :narrow
    end
  end

  describe "precedence between natures" do
    test "a blocker beats everything" do
      policy =
        Diagnosis.diagnose(%{
          blocker: "the pg_dump binary does not exist on this machine",
          conformance: {:nonconforming, "something else"},
          failed_criteria: ["the suite"],
          findings: [finding(:critical)]
        })

      assert policy.nature == :blocker
    end

    test "conformance beats functional and localized" do
      policy =
        Diagnosis.diagnose(%{
          conformance: {:nonconforming, "something else"},
          failed_criteria: ["the suite"],
          findings: [finding(:critical)]
        })

      assert policy.nature == :conformance
    end

    test "functional beats localized" do
      policy =
        Diagnosis.diagnose(%{
          failed_criteria: ["the suite"],
          findings: [finding(:low)]
        })

      assert policy.nature == :functional
    end

    test "a :conforming verdict does NOT trigger the conformance nature" do
      policy = Diagnosis.diagnose(%{conformance: :conforming, findings: [finding(:low)]})

      assert policy.nature == :localized
    end

    test "an empty or blank blocker does not count" do
      for text <- ["", "   "] do
        policy = Diagnosis.diagnose(%{blocker: text, findings: [finding(:low)]})
        assert policy.nature == :localized, "blocker #{inspect(text)} should not count"
      end
    end

    test "a failure with no signal is :functional, not :localized" do
      policy = Diagnosis.diagnose(%{})

      assert policy.nature == :functional
      assert policy.scope == :whole_task
    end

    test "a finding WITHOUT a named file is not localized" do
      policy = Diagnosis.diagnose(%{findings: [finding(:low, file: "")]})

      assert policy.nature == :functional
    end
  end

  describe "turns: narrow for localized, medium for severe or functional" do
    test "a minor localized fix gets the NARROW cap" do
      policy = Diagnosis.diagnose(%{findings: [finding(:low), finding(:medium)]})

      assert policy.width == :narrow
      assert policy.turns == 8
    end

    test "a functional failure gets the MEDIUM cap" do
      policy = Diagnosis.diagnose(%{failed_criteria: ["the suite"]})

      assert policy.width == :medium
      assert policy.turns == 18
    end

    test "a SEVERE defect at a named spot goes up to medium and keeps the narrow scope" do
      for severity <- [:critical, :high] do
        policy = Diagnosis.diagnose(%{findings: [finding(severity)]})

        assert policy.nature == :localized, "#{severity}"
        assert policy.width == :medium, "#{severity}"
        assert {:files, _} = policy.scope
      end
    end

    test "conformance gets the WIDE cap" do
      policy = Diagnosis.diagnose(%{conformance: {:nonconforming, "x"}})

      assert policy.width == :wide
      assert policy.turns == 30
    end

    test "wide is the loop's DEFAULT cap, not a special regime" do
      assert Policy.turns(:wide) == %Factory.Agents.State{}.max_turns
    end

    test "the three widths are strictly increasing" do
      turns = Enum.map(Policy.widths(), &Policy.turns/1)

      assert turns == Enum.sort(turns)
      assert length(Enum.uniq(turns)) == 3
    end
  end

  describe "conformance: whole scope with the GOAL in focus" do
    test "the goal enters the focus first" do
      policy =
        Diagnosis.diagnose(%{
          conformance: {:nonconforming, "implemented search"},
          goal: "sort the player list by score",
          findings: [finding(:high)]
        })

      assert policy.scope == :whole_task
      assert hd(policy.focus) =~ "WHAT WAS ASKED: sort the player list"
      assert Enum.at(policy.focus, 1) =~ "WHY IT FAILED: implemented search"
    end

    test "findings come AFTER the goal, not instead of it" do
      policy =
        Diagnosis.diagnose(%{
          conformance: {:nonconforming, "x"},
          goal: "the goal",
          findings: [finding(:high, problem: "division by zero")]
        })

      assert List.last(policy.focus) =~ "division by zero"
    end

    test "a missing goal is stated, not silently omitted" do
      policy = Diagnosis.diagnose(%{conformance: {:nonconforming, "x"}})

      assert hd(policy.focus) =~ "goal not provided"
    end
  end

  describe "the focus is in severity order" do
    test "critical before high before medium before low" do
      findings = [
        finding(:low, problem: "four"),
        finding(:critical, problem: "one"),
        finding(:medium, problem: "three"),
        finding(:high, problem: "two")
      ]

      focus = Diagnosis.diagnose(%{findings: findings}).focus

      assert Enum.map(focus, &String.slice(&1, 0, 10)) == [
               "[critical]",
               "[high] lib",
               "[medium] l",
               "[low] lib/"
             ]
    end

    test "findings of equal severity keep the reviewer's order" do
      findings = [
        finding(:high, problem: "first"),
        finding(:high, problem: "second"),
        finding(:high, problem: "third")
      ]

      focus = Diagnosis.diagnose(%{findings: findings}).focus

      assert Enum.map(focus, &String.replace(&1, ~r/.* — /u, "")) ==
               ["first", "second", "third"]
    end

    test "the scope is also in severity order, without repeated files" do
      findings = [
        finding(:low, file: "lib/z.ex"),
        finding(:critical, file: "lib/a.ex"),
        finding(:medium, file: "lib/z.ex")
      ]

      assert {:files, ["lib/a.ex", "lib/z.ex"]} =
               Diagnosis.diagnose(%{findings: findings}).scope
    end

    test "the failed criterion enters the focus before the findings" do
      policy =
        Diagnosis.diagnose(%{
          failed_criteria: ["the suite passes", "the format is right"],
          findings: [finding(:critical, problem: "bug")]
        })

      assert hd(policy.focus) == "FAILED CRITERION: the suite passes"
      assert List.last(policy.focus) =~ "bug"
    end
  end

  describe "the model goes up on rework" do
    test "the first run uses the base model" do
      assert Diagnosis.diagnose(%{}, attempts: 0).model == :base
    end

    test "from the second run on it uses the reinforced model" do
      for attempts <- [1, 2, 3] do
        assert Diagnosis.diagnose(%{}, attempts: attempts).model == :reinforced
      end
    end

    test "without :attempts it assumes the first run" do
      assert Diagnosis.diagnose(%{}).model == :base
    end
  end

  describe "the dispatch block" do
    test "states the nature, scope, cap and numbered list" do
      text =
        %{findings: [finding(:critical, problem: "one"), finding(:low, problem: "two")]}
        |> Diagnosis.diagnose()
        |> Policy.for_dispatch()

      assert text =~ "Nature of the failure: localized"
      assert text =~ "ONLY these files: lib/a.ex"
      assert text =~ "Cap for this round: 18 model turns (medium)"
      assert text =~ "1. [critical]"
      assert text =~ "2. [low]"
    end

    test "the whole scope is spelled out" do
      text =
        %{failed_criteria: ["the suite"]}
        |> Diagnosis.diagnose()
        |> Policy.for_dispatch()

      assert text =~ "Scope: the whole task"
    end

    test "with no focus it says so instead of leaving an empty list" do
      text = %{} |> Diagnosis.diagnose() |> Policy.for_dispatch()

      assert text =~ "No named findings."
      refute text =~ "Fix, in this order"
    end
  end
end
