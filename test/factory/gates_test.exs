defmodule Factory.GatesTest do
  @moduledoc """
  The two gates, and the two ABSENCES that make them gates: neither the verifier nor the
  reviewer has any way to fix what it fails.
  """

  use ExUnit.Case, async: true

  alias Factory.Criteria
  alias Factory.Gates.Reviewer
  alias Factory.Gates.Verifier
  alias Factory.Tools.Catalog

  doctest Factory.Gates.Reviewer

  defp result(state, attrs \\ []) do
    default = %{
      text: "a criterion",
      command: "mix test",
      state: state,
      refusal: nil,
      class: nil,
      rerun: false,
      implicit: false,
      output: "",
      mirror: false
    }

    Map.merge(default, Map.new(attrs))
  end

  defp finding(severity, attrs \\ []) do
    default = %{
      severity: severity,
      file: "lib/a.ex",
      line: 10,
      problem: "something wrong"
    }

    Map.merge(default, Map.new(attrs))
  end

  describe "the absence: neither gate can write" do
    test "the verifier gets neither write nor edit" do
      {:ok, tools} = Verifier.tools()

      refute Map.has_key?(tools, "write")
      refute Map.has_key?(tools, "edit")
    end

    test "the reviewer gets neither write nor edit" do
      {:ok, tools} = Reviewer.tools()

      refute Map.has_key?(tools, "write")
      refute Map.has_key?(tools, "edit")
    end

    test "no tool of either has write power, whatever its name" do
      for role <- [Verifier.role(), Reviewer.role()] do
        refute Catalog.can_write?(role), "#{role} must not have write power"
      end
    end

    test "the builder CAN write (otherwise the test above would pass vacuously)" do
      assert Catalog.can_write?("builder")
    end

    test "the reviewer has fewer tools than the verifier" do
      # The reviewer does not run commands either: it reads the diff.
      {:ok, verifier_tools} = Verifier.tools()
      {:ok, reviewer_tools} = Reviewer.tools()

      assert Map.has_key?(verifier_tools, "run")
      refute Map.has_key?(reviewer_tools, "run")
    end
  end

  describe "the reviewer reads the DIFF, not the sources" do
    test "the context has the diff and no source block" do
      context =
        Reviewer.context(
          goal: "add two numbers",
          criteria: "- [ ] adds",
          diff: "+++ b/lib/sum.ex\n+def sum(a, b), do: a + b"
        )

      kinds = Enum.map(context.blocks, &elem(&1, 0))

      assert kinds == [:goal, :criteria, :diff]
      refute :source in kinds
      refute :files in kinds
    end

    test "the reviewer module HAS NO WAY to read the disk" do
      source = File.read!("lib/factory/gates/reviewer.ex")

      for forbidden <- ["File.read", "File.stream", "Path.wildcard", "File.ls"] do
        refute source =~ forbidden, "Reviewer references #{forbidden}: it may only see the diff."
      end
    end

    test "the detector above works and does not pass vacuously" do
      # This test file uses `File.read!`, so the pattern must find it here.
      assert File.read!("test/factory/gates_test.exs") =~ "File.read"
    end

    test "the context does not invent a block when a part is missing" do
      context = Reviewer.context([])

      assert Enum.map(context.blocks, &elem(&1, 0)) == [:goal, :criteria, :diff]
      assert Enum.all?(context.blocks, fn {_kind, text} -> text == "" end)
    end
  end

  describe "conformance and review are INDEPENDENT" do
    test "nonconforming with ZERO findings fails" do
      verdict =
        Reviewer.judge({:nonconforming, "implemented search, the task asked for sorting"}, [])

      refute verdict.approved
      assert verdict.reason == :nonconforming
      assert verdict.findings == []
      assert {:nonconforming, reason} = verdict.conformance
      assert reason =~ "sorting"
    end

    test "conforming with findings also fails" do
      verdict = Reviewer.judge(:conforming, [finding(:high)])

      refute verdict.approved
      assert verdict.reason == :defects
    end

    test "approves only when BOTH answers pass" do
      verdict = Reviewer.judge(:conforming, [])

      assert verdict.approved
      assert verdict.reason == :approved
    end

    test "conformance takes precedence over findings in the reason" do
      verdict = Reviewer.judge({:nonconforming, "something else"}, [finding(:critical)])

      assert verdict.reason == :nonconforming
      assert verdict.findings != []
    end
  end

  describe "the findings format" do
    test "renders as [severity] file:line — problem" do
      text =
        Reviewer.format(%{
          severity: :critical,
          file: "lib/factory/account.ex",
          line: 91,
          problem: "division without a zero guard"
        })

      assert text == "[critical] lib/factory/account.ex:91 — division without a zero guard"
    end

    test "a finding without a line omits the number instead of inventing :1" do
      text =
        Reviewer.format(finding(:medium, file: "lib/b.ex", line: nil, problem: "no test"))

      assert text == "[medium] lib/b.ex — no test"
    end

    test "every severity formats the same way" do
      for severity <- Reviewer.severities() do
        assert Reviewer.format(finding(severity)) =~ "[#{severity}]"
      end
    end

    test "parse_findings/1 and format/1 are inverses" do
      originals = [
        finding(:critical, file: "lib/a.ex", line: 1, problem: "one"),
        finding(:low, file: "lib/b.ex", line: nil, problem: "two")
      ]

      text = Enum.map_join(originals, "\n", &Reviewer.format/1)

      assert Reviewer.parse_findings(text) == originals
    end

    test "parsing ignores surrounding prose" do
      text = """
      ## Review

      Read the whole diff. Two points:

      - [high] lib/a.ex:12 — inverted condition
      Nothing else caught my attention.
      - [low] lib/b.ex:99 — unclear name
      """

      assert [%{severity: :high, line: 12}, %{severity: :low, line: 99}] =
               Reviewer.parse_findings(text)
    end

    test "accepts em dash and hyphen as separator" do
      assert [%{problem: "with em dash"}] =
               Reviewer.parse_findings("[high] lib/a.ex:1 — with em dash")

      assert [%{problem: "with hyphen"}] =
               Reviewer.parse_findings("[high] lib/a.ex:1 - with hyphen")
    end

    test "an unknown severity is not a finding" do
      assert Reviewer.parse_findings("[super-urgent] lib/a.ex:1 — invented") == []
    end

    test "empty or nil text returns an empty list" do
      assert Reviewer.parse_findings("") == []
      assert Reviewer.parse_findings(nil) == []
    end

    test "worst/1 returns the highest severity, not the first in the list" do
      assert Reviewer.worst([finding(:low), finding(:critical), finding(:medium)]) == :critical
      assert Reviewer.worst([finding(:medium), finding(:low)]) == :medium
      assert Reviewer.worst([]) == nil
    end
  end

  describe "the verifier judges from the mechanical pass" do
    test "approves when every criterion with a command passed" do
      verdict = Verifier.judge([result(:passed), result(:not_run)])

      assert verdict.approved
      assert verdict.reason == :approved
    end

    test "fails when some criterion failed by delivery" do
      verdict = Verifier.judge([result(:passed), result(:failed, class: :delivery)])

      refute verdict.approved
      assert verdict.reason == :criterion_failed
    end

    test "does NOT approve with a pending inconclusive criterion" do
      verdict =
        Verifier.judge([
          result(:passed),
          result(:inconclusive, class: :broken_tool)
        ])

      refute verdict.approved
      assert verdict.reason == :no_proof
      refute Criteria.failed?(verdict.results)
    end

    test "a criterion WITHOUT a command does not block approval" do
      verdict = Verifier.judge([result(:not_run, refusal: :no_command)])

      assert verdict.approved
    end

    test "the pass report comes with the verdict" do
      verdict = Verifier.judge([result(:passed, text: "the suite passes")])

      assert verdict.report =~ "the suite passes"
      assert verdict.report =~ "Proof levels:"
    end

    test "an empty list approves, since there is nothing to fail" do
      assert Verifier.judge([]).approved
    end
  end

  describe "the verifier context" do
    test "has the task and the mechanical pass, and NOT the diff" do
      context = Verifier.context("## Goal\nadd", "### Mechanical pass")

      kinds = Enum.map(context.blocks, &elem(&1, 0))

      assert kinds == [:task, :mechanical_pass]
      refute :diff in kinds
    end

    test "the context role is the catalog role" do
      assert Verifier.context("", "").role == Verifier.role()
      assert Reviewer.context([]).role == Reviewer.role()
    end
  end
end
