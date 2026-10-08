defmodule Factory.Tasks.StateMachineTest do
  @moduledoc """
  Sweeps the 64 state combinations, one per test.

  The `@legal` list is written by hand from the plan, not copied from the module: a test that
  reads the production table only proves two files agree. The 46 illegal ones are the
  computed complement, so both a missing and an invented edge fail.
  """

  use ExUnit.Case, async: true

  alias Factory.Tasks.StateMachine

  doctest Factory.Tasks.StateMachine

  @known_states [
    :backlog,
    :ready,
    :in_progress,
    :in_testing,
    :in_review,
    :done,
    :blocked,
    :cancelled
  ]

  # Happy path, the two rejections, then the exits from any live state (`done` excluded,
  # `blocked -> cancelled` included).
  @legal [
    {:backlog, :ready},
    {:ready, :in_progress},
    {:in_progress, :in_testing},
    {:in_testing, :in_review},
    {:in_review, :done},
    {:in_testing, :in_progress},
    {:in_review, :in_progress},
    {:backlog, :blocked},
    {:ready, :blocked},
    {:in_progress, :blocked},
    {:in_testing, :blocked},
    {:in_review, :blocked},
    {:backlog, :cancelled},
    {:ready, :cancelled},
    {:in_progress, :cancelled},
    {:in_testing, :cancelled},
    {:in_review, :cancelled},
    {:blocked, :cancelled}
  ]

  @illegal for from <- @known_states,
               to <- @known_states,
               {from, to} not in @legal,
               do: {from, to}

  describe "the 18 legal transitions" do
    for {from, to} <- @legal do
      test "#{from} -> #{to} is accepted" do
        assert StateMachine.can?(unquote(from), unquote(to))
        assert StateMachine.check(unquote(from), unquote(to)) == :ok
      end
    end
  end

  describe "the 46 illegal transitions" do
    for {from, to} <- @illegal do
      test "#{from} -> #{to} is rejected with a named error" do
        refute StateMachine.can?(unquote(from), unquote(to))

        assert StateMachine.check(unquote(from), unquote(to)) ==
                 {:error, {:invalid_transition, unquote(from), unquote(to)}}
      end
    end
  end

  describe "the sweep is not empty" do
    test "the two lists cover exactly the 64 combinations" do
      assert length(@legal) == 18
      assert length(@illegal) == 46
      assert length(@legal) + length(@illegal) == 8 * 8
    end

    test "no combination appears in both lists" do
      assert MapSet.disjoint?(MapSet.new(@legal), MapSet.new(@illegal))
    end

    test "the machine's states are the schema's, nothing more and nothing less" do
      assert Enum.sort(StateMachine.states()) == Enum.sort(@known_states)
    end
  end

  describe "map properties" do
    test "no state transitions to itself" do
      for state <- @known_states do
        refute StateMachine.can?(state, state), "#{state} -> #{state} should be rejected"
      end
    end

    test "done and cancelled lead nowhere" do
      assert StateMachine.terminal?(:done)
      assert StateMachine.terminal?(:cancelled)
    end

    test "blocked is NOT terminal: replanning cancels the original from it" do
      refute StateMachine.terminal?(:blocked)
      assert StateMachine.targets(:blocked) == [:cancelled]
    end

    test "an unknown state leads nowhere instead of crashing" do
      assert StateMachine.targets(:invented) == []
      refute StateMachine.can?(:invented, :ready)

      assert {:error, {:invalid_transition, :invented, :ready}} =
               StateMachine.check(:invented, :ready)
    end

    test "only `in_progress` spends an attempt" do
      spending = Enum.filter(@known_states, &StateMachine.hands_to_builder?/1)
      assert spending == [:in_progress]
    end

    test "each of the three paths to in_progress hands the task to a builder" do
      for from <- [:ready, :in_testing, :in_review] do
        assert StateMachine.can?(from, :in_progress)
        assert StateMachine.hands_to_builder?(:in_progress)
      end
    end
  end
end
