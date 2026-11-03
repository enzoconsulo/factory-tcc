defmodule Factory.Gates.ReviewerTest do
  @moduledoc """
  `parse_conformance/1`: reading the conformance verdict from the agent's structured report,
  in the same spirit as `parse_findings/1` (see `test/factory/gates_test.exs`).
  """

  use ExUnit.Case, async: true

  alias Factory.Gates.Reviewer

  describe "explicit format: [conformance] conforming | nonconforming — reason" do
    test "declares nonconforming with a reason" do
      assert {:nonconforming, reason} =
               Reviewer.parse_conformance(
                 "[conformance] nonconforming — implemented something else"
               )

      assert reason == "implemented something else"
    end

    test "declares conforming explicitly" do
      assert Reviewer.parse_conformance("[conformance] conforming") == :conforming
    end

    test "accepts em dash and hyphen as separator, like parse_findings/1" do
      assert {:nonconforming, "with em dash"} =
               Reviewer.parse_conformance("[conformance] nonconforming — with em dash")

      assert {:nonconforming, "with hyphen"} =
               Reviewer.parse_conformance("[conformance] nonconforming - with hyphen")
    end

    test "accepts the hyphenated 'non-conforming'" do
      assert {:nonconforming, "reason"} =
               Reviewer.parse_conformance("[conformance] non-conforming — reason")
    end
  end

  describe "a missing declaration NEVER fails on its own" do
    test "text that does not mention the field returns :conforming" do
      assert Reviewer.parse_conformance("just a summary of what was done, without the field") ==
               :conforming
    end

    test "empty or nil text returns :conforming" do
      assert Reviewer.parse_conformance("") == :conforming
      assert Reviewer.parse_conformance(nil) == :conforming
    end

    test "a malformed line (no reason after the dash) is ignored instead of failing" do
      assert Reviewer.parse_conformance("[conformance] nonconforming") == :conforming
    end

    test "surrounding prose is ignored" do
      text = """
      ## summary

      Implemented the requested module, checked the criteria one by one.

      [conformance] conforming
      """

      assert Reviewer.parse_conformance(text) == :conforming
    end
  end

  describe "several matching lines: the LAST wins" do
    test "the agent may restate its verdict later in the same report" do
      text = """
      [conformance] conforming

      On second thought, part of the request is missing.

      [conformance] nonconforming — part X is missing
      """

      assert {:nonconforming, "part X is missing"} = Reviewer.parse_conformance(text)
    end
  end
end
