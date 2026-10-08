defmodule Factory.MilestoneE4Test do
  @moduledoc """
  Proof of the E4 milestone: a task goes through the six states, is rejected ON PURPOSE,
  and after rework is completed, with everything recorded in transactions.

  The proof is adversarial: the verifier's first verdict rejects with a concrete reason (the
  error message required by the criterion does not match), and only the second pass, with
  the model escalated by `Factory.Rework.Ladder`, fixes it. Everything here is
  `Factory.Tasks.Transition` called in sequence; no real agent and no network are involved.
  """

  use Factory.DataCase, async: true

  alias Factory.Cost.Pricing
  alias Factory.Cost.Usage, as: CostUsage
  alias Factory.Projects.Project
  alias Factory.Provider.Usage, as: ReportedUsage
  alias Factory.Publishing.Markdown
  alias Factory.Rework.Ladder
  alias Factory.Tasks.Cycle
  alias Factory.Tasks.Dispatch
  alias Factory.Tasks.Task
  alias Factory.Tasks.Transition
  alias Factory.Tasks.Usage

  setup do
    project =
      %Project{}
      |> Project.changeset(%{
        name: "milestone-e4-#{System.unique_integer([:positive])}",
        path: "C:/tmp/milestone-e4"
      })
      |> Repo.insert!()

    task =
      %Task{}
      |> Task.changeset(%{
        project_id: project.id,
        code: "T-#{900 + System.unique_integer([:positive])}",
        title: "criterion requires the exact error message",
        status: :ready
      })
      |> Repo.insert!()

    %{task: task}
  end

  # `to_record/3` requires `:dispatch_id`, but the dispatch is created inside the same Multi
  # as the transition, which sets the real id. 0 is only a placeholder, never stored.
  defp usage_record(model, reported_attrs) do
    {:ok, record} =
      CostUsage.to_record(model, struct(ReportedUsage, reported_attrs),
        dispatch_id: 0,
        turn: 1
      )

    record
  end

  test "six states, deliberate rejection, rework and completion", %{task: task} do
    history = [task.status]

    # --- Cycle 1: ready -> in_progress (handed to the builder) ---
    assert {:ok, task} = Transition.apply(task, :in_progress)
    assert task.status == :in_progress
    assert task.attempts == 1
    history = history ++ [task.status]

    builder_usage_1 =
      usage_record("sonnet-5", %{
        input_tokens: 6_000,
        cache_write_tokens: 400,
        cache_read_tokens: 5_200,
        output_tokens: 900,
        duration_ms: 14_000,
        cache_ttl: :five_minutes
      })

    # --- in_progress -> in_testing (builder finishes cycle 1) ---
    assert {:ok, task} =
             Transition.apply(task, :in_testing,
               role: "builder",
               report: "Validation implemented. Error message: \"invalid\".",
               dispatch: %{provider: "claude_cli", model: "sonnet-5", turns: 1},
               usages: [builder_usage_1]
             )

    assert task.status == :in_testing
    # Only entering in_progress spends an attempt.
    assert task.attempts == 1
    history = history ++ [task.status]

    verifier_usage_1 =
      usage_record("haiku-4.5", %{
        input_tokens: 1_800,
        cache_read_tokens: 1_500,
        output_tokens: 150,
        duration_ms: 3_000
      })

    # --- in_testing -> in_progress: the verifier rejects on purpose ---
    # The criterion required the EXACT message "invalid message: required field", and the
    # builder wrote "invalid": a delivery failure, not a broken command.
    assert {:ok, task} =
             Transition.apply(task, :in_progress,
               role: "verifier",
               outcome: "rejected",
               report:
                 "Criterion 2 failed: expected 'invalid message: required field', " <>
                   "got 'invalid'.",
               dispatch: %{provider: "claude_cli", model: "haiku-4.5", turns: 1},
               usages: [verifier_usage_1]
             )

    assert task.status == :in_progress
    # Rework also hands the task to the builder: the 2nd attempt starts here.
    assert task.attempts == 2
    history = history ++ [task.status]

    # --- The rework ladder decides the next dispatch: the MODEL GOES UP ---
    # `attempts: 1` = runs already finished before this decision.
    assert {:ok, decision} = Ladder.next_step(%{attempts: 1})
    assert decision.step == :escalate_model
    assert decision.model == :reinforced

    model_cycle_1 = "sonnet-5"
    model_cycle_2 = "opus-5"
    assert model_cycle_2 != model_cycle_1

    builder_usage_2 =
      usage_record(model_cycle_2, %{
        input_tokens: 6_400,
        cache_write_tokens: 200,
        cache_read_tokens: 5_800,
        output_tokens: 950,
        duration_ms: 15_500,
        cache_ttl: :five_minutes
      })

    # --- Cycle 2: in_progress -> in_testing (builder fixes, on the reinforced model) ---
    assert {:ok, task} =
             Transition.apply(task, :in_testing,
               role: "builder",
               report: "Message fixed: now emits 'invalid message: required field'.",
               dispatch: %{provider: "claude_cli", model: model_cycle_2, turns: 1},
               usages: [builder_usage_2]
             )

    assert task.status == :in_testing
    assert task.attempts == 2
    history = history ++ [task.status]

    verifier_usage_2 =
      usage_record("haiku-4.5", %{
        input_tokens: 1_900,
        cache_read_tokens: 1_600,
        output_tokens: 140,
        duration_ms: 2_800
      })

    # --- in_testing -> in_review: the verifier approves this time ---
    assert {:ok, task} =
             Transition.apply(task, :in_review,
               role: "verifier",
               outcome: "approved",
               report: "Criterion 2 checks: exact message matches.",
               dispatch: %{provider: "claude_cli", model: "haiku-4.5", turns: 1},
               usages: [verifier_usage_2]
             )

    assert task.status == :in_review
    assert task.attempts == 2
    history = history ++ [task.status]

    reviewer_usage =
      usage_record("sonnet-5", %{
        input_tokens: 4_000,
        cache_read_tokens: 3_500,
        output_tokens: 300,
        duration_ms: 5_000
      })

    # --- in_review -> done: the reviewer approves ---
    assert {:ok, task} =
             Transition.apply(task, :done,
               role: "reviewer",
               outcome: "approved without findings",
               report: "Checked the cycle 2 diff against the criterion: it complies.",
               dispatch: %{provider: "claude_cli", model: "sonnet-5", turns: 1},
               usages: [reviewer_usage]
             )

    assert task.status == :done
    history = history ++ [task.status]
    final_task = task

    # === Criterion 1: the six states, with rejection and rework, until done ===
    # The task starts in `ready` (backlog would need dependencies, outside this milestone).
    # Passing twice through in_progress/in_testing is the proof of rework.
    assert history == [
             :ready,
             :in_progress,
             :in_testing,
             :in_progress,
             :in_testing,
             :in_review,
             :done
           ]

    # === Criterion 2: attempts equals the number of BUILDER dispatches, and the model went
    # up on the 2nd ===
    builder_dispatches =
      Dispatch
      |> join(:inner, [d], c in Cycle, on: c.id == d.cycle_id)
      |> where([d, c], c.task_id == ^final_task.id and c.role == "builder")
      |> order_by([d, c], asc: c.number)
      |> Repo.all()

    assert length(builder_dispatches) == final_task.attempts
    assert final_task.attempts == 2
    assert Enum.map(builder_dispatches, & &1.model) == [model_cycle_1, model_cycle_2]

    # === Criterion 3: each cycle's cost can be queried SEPARATELY ===
    cost_per_cycle =
      Usage
      |> join(:inner, [u], d in Dispatch, on: d.id == u.dispatch_id)
      |> join(:inner, [u, d], c in Cycle, on: c.id == d.cycle_id)
      |> where([u, d, c], c.task_id == ^final_task.id)
      |> group_by([u, d, c], c.number)
      |> order_by([u, d, c], asc: c.number)
      |> select([u, d, c], {c.number, sum(u.cost_usd)})
      |> Repo.all()

    assert [{1, cost_cycle_1}, {2, cost_cycle_2}] = cost_per_cycle
    assert Decimal.compare(cost_cycle_1, Decimal.new(0)) == :gt
    assert Decimal.compare(cost_cycle_2, Decimal.new(0)) == :gt
    # Two independent queries with their own values, not a single total.
    assert Decimal.compare(cost_cycle_1, cost_cycle_2) != :eq

    total_cost =
      Usage
      |> join(:inner, [u], d in Dispatch, on: d.id == u.dispatch_id)
      |> join(:inner, [u, d], c in Cycle, on: c.id == d.cycle_id)
      |> where([u, d, c], c.task_id == ^final_task.id)
      |> select([u], sum(u.cost_usd))
      |> Repo.one()

    assert Decimal.compare(total_cost, Decimal.add(cost_cycle_1, cost_cycle_2)) == :eq

    # Cross-check: the total matches the five original reports summed by hand.
    expected_total =
      [
        {"sonnet-5", builder_usage_1},
        {"haiku-4.5", verifier_usage_1},
        {model_cycle_2, builder_usage_2},
        {"haiku-4.5", verifier_usage_2},
        {"sonnet-5", reviewer_usage}
      ]
      |> Enum.map(fn {_model, record} -> record.cost_usd end)
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    assert Decimal.compare(total_cost, expected_total) == :eq

    # === Criterion 4: the generated markdown reflects the final state, with the rework
    # history visible ===
    markdown_task =
      Repo.get!(Task, final_task.id)
      |> Repo.preload([
        :project,
        :specialist,
        :replanned_from,
        :areas,
        :criteria,
        dependencies: :depends_on,
        cycles: from(c in Cycle, order_by: c.number)
      ])

    markdown = Markdown.generate(markdown_task)

    assert markdown =~ "status: done"
    assert markdown =~ "attempts: 2"
    # Both verifier passes (rejected and approved) are shown, not only the final verdict.
    assert markdown =~ "### Cycle 1"
    assert markdown =~ "### Cycle 2"
    assert markdown =~ "expected 'invalid message: required field'"
    assert markdown =~ "Criterion 2 checks"
    assert markdown =~ "Checked the cycle 2 diff"

    # The comparison uses the price table checked on this date.
    assert Pricing.checked_on() == ~D[2026-08-28]
  end
end
