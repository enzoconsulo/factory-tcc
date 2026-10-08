defmodule Factory.Agents.ToolBudgetTest do
  @moduledoc """
  The two numbers, and the invariant that keeps them consistent: the threshold is always
  above the role's largest target.
  """

  use Factory.DataCase, async: true

  alias Factory.Agents.ToolBudget, as: Budget
  alias Factory.Projects.Project
  alias Factory.Tasks.Cycle
  alias Factory.Tasks.Dispatch
  alias Factory.Tasks.Task

  describe "the measured numbers" do
    test "the builder target scales with areas: 30 / 45 / 60" do
      assert Budget.target("builder", 1) == 30
      assert Budget.target("builder", 2) == 30
      assert Budget.target("builder", 3) == 45
      assert Budget.target("builder", 4) == 60
      assert Budget.target("builder", 9) == 60
    end

    test "the verifier target is 25 and the reviewer's is 20, flat" do
      assert Budget.target("verifier", 1) == 25
      assert Budget.target("verifier", 7) == 25
      assert Budget.target("reviewer", 1) == 20
      assert Budget.target("reviewer", 7) == 20
    end

    test "the thrashing threshold is the measured p90, FLAT for the builder" do
      assert Budget.threshold("builder") == 65
      assert Budget.threshold("verifier") == 37
      assert Budget.threshold("reviewer") == 28
    end

    test "an unknown role falls back to a default, not zero" do
      assert Budget.target("planner", 1) == 60
      assert Budget.threshold("planner") == 65
    end

    test "the default threshold sits above the default target" do
      assert Budget.threshold("role-nobody-measured") >
               Budget.target("role-nobody-measured", 1)
    end
  end

  describe "THE INVARIANT: the threshold is always above the role's largest target" do
    test "holds for every role" do
      for role <- ~w[builder verifier reviewer planner] do
        assert Budget.consistent?(role), "the threshold of #{role} cannot be below its target"
      end
    end

    test "the builder at 65 is above the maximum target of 60" do
      assert Budget.threshold("builder") > Budget.target("builder", 8)
    end

    test "target and threshold are DIFFERENT numbers, not synonyms" do
      for role <- ~w[builder verifier reviewer] do
        refute Budget.threshold(role) == Budget.target(role, 1)
      end
    end
  end

  describe "exceeding the cap RECORDS and does NOT interrupt" do
    test "going over the target is flagged and the tally returns normally" do
      tally = Budget.tally("verifier", 32, areas: 2)

      assert tally.over_target
      assert tally.calls == 32
      assert tally.target == 25
    end

    test "going over the target WITHOUT going over the threshold is not thrashing" do
      tally = Budget.tally("verifier", 32)

      assert tally.over_target
      refute tally.thrashing
    end

    test "going over the THRESHOLD is thrashing" do
      tally = Budget.tally("verifier", 40)

      assert tally.thrashing
      assert tally.threshold == 37
    end

    test "staying within the target flags nothing" do
      tally = Budget.tally("reviewer", 10)

      refute tally.over_target
      refute tally.thrashing
    end

    test "the warning exists only when there is thrashing" do
      refute Budget.warning(Budget.tally("reviewer", 10))
      refute Budget.warning(Budget.tally("verifier", 32))

      warning = Budget.warning(Budget.tally("verifier", 40))
      assert warning =~ "40 tool calls"
      assert warning =~ "37"
    end

    test "the warning points at SIZING, not at the agent" do
      warning = Budget.warning(Budget.tally("builder", 80))

      assert warning =~ "badly sized task"
      assert warning =~ "not an inefficient agent"
    end

    test "the tally never carries a stop instruction" do
      tally = Budget.tally("builder", 500)

      assert Map.keys(tally) |> Enum.sort() ==
               ~w[calls over_target role target thrashing threshold]a

      refute Map.has_key?(tally, :stop)
      refute Map.has_key?(tally, :cut)
    end
  end

  describe "the overrun is readable in `dispatches`" do
    setup do
      project =
        Repo.insert!(
          Project.changeset(%Project{}, %{
            name: "p-#{System.unique_integer([:positive])}",
            path: "C:/tmp/p"
          })
        )

      task =
        Repo.insert!(
          Task.changeset(%Task{}, %{
            project_id: project.id,
            code: "T-#{100 + System.unique_integer([:positive])}",
            title: "budget"
          })
        )

      cycle =
        Repo.insert!(Cycle.changeset(%Cycle{}, %{task_id: task.id, number: 1, role: "verifier"}))

      {:ok, cycle: cycle}
    end

    test "the dispatch stores the budget outcome", %{cycle: cycle} do
      tally = Budget.tally("verifier", 40)

      dispatch =
        Repo.insert!(
          Dispatch.changeset(
            %Dispatch{},
            Map.merge(
              %{cycle_id: cycle.id, provider: "Provider.Fake", model: "haiku-4.5", turns: 12},
              Budget.for_dispatch(tally)
            )
          )
        )

      assert Repo.get!(Dispatch, dispatch.id).outcome == "thrashing"
    end

    test "the three possible outcomes are distinguishable" do
      assert Budget.for_dispatch(Budget.tally("reviewer", 5)).outcome == "within_target"
      assert Budget.for_dispatch(Budget.tally("reviewer", 24)).outcome == "over_target"
      assert Budget.for_dispatch(Budget.tally("reviewer", 40)).outcome == "thrashing"
    end

    test "the tally carries cap AND actual, which the rework diagnosis needs" do
      tally = Budget.tally("builder", 80, areas: 5)

      assert tally.target == 60
      assert tally.threshold == 65
      assert tally.calls == 80
    end
  end

  describe "the source of the numbers is documented" do
    test "the module doc cites the sample and the p90" do
      source = File.read!("lib/factory/agents/tool_budget.ex")

      assert source =~ "thrashing threshold"
      assert source =~ "135 real dispatch steps"
      assert source =~ "p90"
    end

    test "the module doc records that it MEASURES AND NEVER CUTS, and why" do
      source = File.read!("lib/factory/agents/tool_budget.ex")

      assert source =~ "MEASURES AND NEVER CUTS"
      assert source =~ "costs the same and"
    end
  end
end
