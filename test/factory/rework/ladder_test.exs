defmodule Factory.Rework.LadderTest do
  @moduledoc """
  One test per step and, more importantly, one per step that must NOT fire: climbing too early
  spends an expensive model on an easy task, climbing too late burns the cycles on a bet that
  already failed.
  """

  use ExUnit.Case, async: true

  alias Factory.Rework.Ladder

  doctest Factory.Rework.Ladder

  defp situation(attrs), do: Map.new(attrs)

  describe "step 1 — escalate model on the 1st failure" do
    test "one failed run escalates to the reinforced model" do
      assert {:ok, decision} = Ladder.next_step(situation(attempts: 1))

      assert decision.step == :escalate_model
      assert decision.model == :reinforced
      assert decision.specialist == :keep
      assert decision.reason =~ "pays the whole cycle again"
    end

    test "does NOT escalate before any failure" do
      assert {:ok, decision} = Ladder.next_step(situation(attempts: 0))

      assert decision.model == :base
      assert decision.reason =~ "first run"
    end

    test "escalates the model when there is NO specialist to switch" do
      assert {:ok, %{step: :escalate_model}} =
               Ladder.next_step(situation(attempts: 2, specialists_used: [nil, nil]))
    end
  end

  describe "step 2 — switch specialist on the 2nd failure under the SAME one" do
    test "two runs with the same specialist switch to the generic reinforced builder" do
      assert {:ok, decision} =
               Ladder.next_step(
                 situation(attempts: 2, specialists_used: ["frontend", "frontend"])
               )

      assert decision.step == :switch_specialist
      assert decision.specialist == :generic_reinforced
      assert decision.model == :reinforced
    end

    test "the switch is RECORDED with a reason naming the specialist" do
      {:ok, decision} =
        Ladder.next_step(situation(attempts: 2, specialists_used: ["database", "database"]))

      assert decision.reason =~ "database"
      assert decision.reason =~ "before anyone knew where the task would fail"
      assert decision.reason =~ "biased"
    end

    test "does NOT switch on the first failure, even with a specialist" do
      assert {:ok, %{step: :escalate_model}} =
               Ladder.next_step(situation(attempts: 1, specialists_used: ["frontend"]))
    end

    test "does NOT switch if both cycles used DIFFERENT specialists" do
      assert {:ok, %{step: :escalate_model}} =
               Ladder.next_step(
                 situation(attempts: 2, specialists_used: ["frontend", "database"])
               )
    end

    test "a single-item specialist list is not 'twice'" do
      assert {:ok, %{step: :escalate_model}} =
               Ladder.next_step(situation(attempts: 2, specialists_used: ["frontend"]))
    end
  end

  describe "step 3 — replan when the 3 cycles are exhausted" do
    test "exhausted cycles go to replanning" do
      assert {:ok, decision} = Ladder.next_step(situation(attempts: 3))

      assert decision.step == :replan
      assert decision.reason =~ "SIZING"
    end

    test "does NOT replan before exhaustion" do
      for attempts <- 0..2 do
        assert {:ok, decision} = Ladder.next_step(situation(attempts: attempts))
        refute decision.step == :replan, "attempts=#{attempts} should not replan"
      end
    end

    test "exhaustion beats switching specialist" do
      assert {:ok, %{step: :replan}} =
               Ladder.next_step(
                 situation(attempts: 3, specialists_used: ["frontend", "frontend"])
               )
    end

    test "the limit is 3 and is declared in one place" do
      assert Ladder.max_attempts() == 3

      assert {:ok, %{step: :escalate_model}} =
               Ladder.next_step(situation(attempts: Ladder.max_attempts() - 1))

      assert {:ok, %{step: :replan}} =
               Ladder.next_step(situation(attempts: Ladder.max_attempts()))
    end
  end

  describe "step 4 — block when already the result of a replan" do
    test "a task with replanned_from blocks instead of replanning again" do
      assert {:stop, {:blocked, reason}} =
               Ladder.next_step(situation(attempts: 3, replanned_from: 42))

      assert reason =~ "once per lineage"
    end

    test "a nil or empty replanned_from does NOT block" do
      for value <- [nil, ""] do
        assert {:ok, %{step: :replan}} =
                 Ladder.next_step(situation(attempts: 3, replanned_from: value)),
               "replanned_from=#{inspect(value)} should not block"
      end
    end

    test "a replanned task with cycles left still works" do
      assert {:ok, %{step: :escalate_model}} =
               Ladder.next_step(situation(attempts: 1, replanned_from: 42))
    end
  end

  describe "the per-round dispatch cap — defence in depth" do
    test "cuts EVEN with a correct counter and cycles left" do
      assert {:stop, :max_dispatches} =
               Ladder.next_step(
                 situation(attempts: 1, dispatches_in_round: Ladder.max_dispatches())
               )
    end

    test "the cap comes BEFORE any other decision, including blocking" do
      assert {:stop, :max_dispatches} =
               Ladder.next_step(
                 situation(
                   attempts: 3,
                   replanned_from: 42,
                   dispatches_in_round: Ladder.max_dispatches() + 5
                 )
               )
    end

    test "below the cap it does not cut" do
      assert {:ok, _decision} =
               Ladder.next_step(
                 situation(attempts: 1, dispatches_in_round: Ladder.max_dispatches() - 1)
               )
    end

    test "the cap does NOT block the task, it only removes it from this round" do
      assert {:stop, reason} =
               Ladder.next_step(situation(attempts: 1, dispatches_in_round: 99))

      assert reason == :max_dispatches
      refute match?({:blocked, _}, reason)
    end

    test "the cap fits the worst legitimate case with room to spare" do
      assert Ladder.max_dispatches() > Ladder.max_attempts() * 3
    end

    test "without dispatches_in_round it assumes zero" do
      assert {:ok, _decision} = Ladder.next_step(situation(attempts: 1))
    end
  end

  describe "the whole ladder, walked" do
    test "a task without a specialist escalates, replans and stops replanning" do
      path =
        for attempts <- 0..3 do
          case Ladder.next_step(situation(attempts: attempts)) do
            {:ok, decision} -> decision.step
            {:stop, reason} -> reason
          end
        end

      assert path == [:escalate_model, :escalate_model, :escalate_model, :replan]
    end

    test "a task WITH a specialist goes through all four steps" do
      steps =
        [
          %{attempts: 1, specialists_used: ["frontend"]},
          %{attempts: 2, specialists_used: ["frontend", "frontend"]},
          %{attempts: 3, specialists_used: ["frontend", "frontend", nil]},
          %{attempts: 3, specialists_used: ["frontend"], replanned_from: 7}
        ]
        |> Enum.map(fn situation ->
          case Ladder.next_step(situation) do
            {:ok, decision} -> decision.step
            {:stop, {:blocked, _reason}} -> :block
          end
        end)

      assert steps == [:escalate_model, :switch_specialist, :replan, :block]
    end

    test "every decision carries a written reason" do
      situations = [
        %{attempts: 0},
        %{attempts: 1},
        %{attempts: 2, specialists_used: ["a", "a"]},
        %{attempts: 3}
      ]

      for s <- situations do
        assert {:ok, decision} = Ladder.next_step(s)
        assert is_binary(decision.reason) and decision.reason != ""
      end
    end
  end
end
