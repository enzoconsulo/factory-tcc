defmodule Factory.Prompt.PrefixTest do
  @moduledoc """
  Locks the main cost lever. The key test builds the prefix TWICE and fails if the bytes
  differ: without identical bytes across dispatches, each one writes a new cached prefix.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Factory.Prompt.Block
  alias Factory.Prompt.Prefix

  # Large enough to exceed Haiku's minimum (4096 tokens ~ 16k characters), so the warning
  # does not fire in tests that are not about it.
  defp long_doctrine, do: String.duplicate("doctrine of the builder role. ", 700)

  # Builds a short prefix capturing the expected minimum-size warning, keeping the suite
  # output readable without disabling the warning itself.
  defp short_prefix(parts) do
    {built, _log} =
      with_log(fn -> Prefix.build("opus-5", parts) end)

    built
  end

  defp parts(extra \\ []) do
    Keyword.merge(
      [
        tools: ["read", "write", "edit"],
        doctrine: long_doctrine(),
        index: "# MAP\n- `lib/factory.ex`",
        task: "task: build the prefix"
      ],
      extra
    )
  end

  describe "identical bytes — the property the savings rely on" do
    test "building twice, at different moments, produces IDENTICAL bytes" do
      first = Prefix.build("opus-5", parts())
      Process.sleep(5)
      second = Prefix.build("opus-5", parts())

      assert first.text == second.text
      assert first.cache_breakpoints == second.cache_breakpoints
    end

    test "nothing volatile goes in: no date, hash or counter" do
      %{text: text} = Prefix.build("opus-5", parts())

      refute text =~ Date.to_iso8601(Date.utc_today())
      refute text =~ ~r/\b[0-9a-f]{7,40}\b/
      refute text =~ "generated at"
    end

    test "the order is tools, doctrine, index, task — not insertion order" do
      %{text: text} =
        short_prefix(
          task: "ZZZ-TASK",
          index: "CCC-INDEX",
          doctrine: "BBB-DOCTRINE",
          tools: "AAA-TOOLS"
        )

      assert :binary.match(text, "AAA") < :binary.match(text, "BBB")
      assert :binary.match(text, "BBB") < :binary.match(text, "CCC")
      assert :binary.match(text, "CCC") < :binary.match(text, "ZZZ")
    end

    test "a missing part simply produces no block" do
      %{blocks: blocks} = short_prefix(tools: "only this")

      assert length(blocks) == 1
      assert hd(blocks).kind == :tools
    end
  end

  describe "every collection is sorted before serializing" do
    test "a shuffled map always produces the same text" do
      one_order = %{zebra: 1, alpha: 2, middle: 3, beta: 4}
      other_order = %{beta: 4, middle: 3, alpha: 2, zebra: 1}

      assert Block.serialize(one_order) == Block.serialize(other_order)
    end

    test "the serialized text comes out in alphabetical key order" do
      text = Block.serialize(%{zebra: 1, alpha: 2, middle: 3})

      assert text == "alpha: 2\nmiddle: 3\nzebra: 1"
    end

    test "a keyword list is treated as a map and also comes out sorted" do
      assert Block.serialize(zebra: 1, alpha: 2) == Block.serialize(alpha: 2, zebra: 1)
    end

    test "a nested map is also sorted" do
      one = Block.serialize(%{outer: %{zebra: 1, alpha: 2}})
      other = Block.serialize(%{outer: %{alpha: 2, zebra: 1}})

      assert one == other
    end

    test "a prefix built with a shuffled map gives identical bytes" do
      one = Prefix.build("opus-5", parts(tools: %{read: 1, write: 2, edit: 3}))
      other = Prefix.build("opus-5", parts(tools: %{edit: 3, read: 1, write: 2}))

      assert one.text == other.text
    end

    test "a list keeps the given order — the order IS the information" do
      assert Block.serialize(["c", "a", "b"]) == "c\na\nb"
    end
  end

  describe "cache breakpoints" do
    test "never more than 4, even with more marked blocks" do
      %{cache_breakpoints: breakpoints} = Prefix.build("opus-5", parts())

      assert breakpoints <= Prefix.max_breakpoints()
    end

    test "stable blocks are marked and the task block is NOT" do
      %{blocks: blocks} = Prefix.build("opus-5", parts())
      mark = Map.new(blocks, &{&1.kind, &1.cache_breakpoint})

      assert mark[:tools]
      assert mark[:doctrine]
      assert mark[:index]

      # The task changes on every dispatch: marking it would pay writes and never get reads.
      refute mark[:task]
    end

    test "with MORE marked blocks than the API accepts, the excess loses the mark" do
      extras =
        Enum.map(1..6, fn n ->
          %Block{kind: :doctrine, text: "extra block #{n}", cache_breakpoint: true}
        end)

      result = Prefix.build("opus-5", parts(blocks: extras))

      assert length(result.blocks) == 10, "all blocks are still there"
      assert result.cache_breakpoints == 4, "only the MARK is limited, not the content"
    end

    test "the most VOLATILE block loses the mark, not the first" do
      extras =
        Enum.map(1..3, fn n ->
          %Block{kind: :index, text: "extra index #{n}", cache_breakpoint: true}
        end)

      %{blocks: blocks} = Prefix.build("opus-5", parts(blocks: extras))

      marked = Enum.filter(blocks, & &1.cache_breakpoint)
      last_marked = List.last(marked)
      last_position = Enum.find_index(blocks, &(&1 == last_marked))

      assert length(marked) == 4
      assert last_position < length(blocks) - 1, "the last blocks were left unmarked"
      assert Enum.take(blocks, 4) |> Enum.all?(& &1.cache_breakpoint)
    end

    test "extra blocks go into their kind's position, not at the end" do
      extra = %Block{kind: :tools, text: "EXTRA-TOOL", cache_breakpoint: false}

      %{text: text} =
        short_prefix(doctrine: "DOCTRINE", blocks: [extra], task: "TASK")

      assert :binary.match(text, "EXTRA-TOOL") < :binary.match(text, "DOCTRINE")
      assert :binary.match(text, "DOCTRINE") < :binary.match(text, "TASK")
    end
  end

  describe "minimum cacheable size — per model, not monotonic" do
    test "the table is the one the API publishes" do
      assert Prefix.min_cacheable("opus-5") == 512
      assert Prefix.min_cacheable("sonnet-5") == 1024
      assert Prefix.min_cacheable("haiku-4.5") == 4096
    end

    test "haiku requires MORE than opus — the order is not the intuitive one" do
      assert Prefix.min_cacheable("haiku-4.5") > Prefix.min_cacheable("opus-5")
    end

    test "an unknown model falls back to a conservative default" do
      assert Prefix.min_cacheable("new-model") == 1024
    end

    test "a short prefix logs a WARNING with the minimum" do
      log =
        capture_log(fn ->
          Prefix.build("haiku-4.5", tools: "too short")
        end)

      assert log =~ "4096"
      assert log =~ "haiku-4.5"
      assert log =~ "will not be cached"
    end

    test "the warning is a WARNING, not an error: the short prefix is still built" do
      result =
        capture_log(fn ->
          assert %{text: text, cacheable: false} =
                   Prefix.build("haiku-4.5", tools: "short")

          assert text =~ "short"
        end)

      assert result =~ "BELOW the minimum"
    end

    test "a large enough prefix does NOT warn" do
      log = capture_log(fn -> Prefix.build("haiku-4.5", parts()) end)

      assert log == ""
    end

    test "the same prefix caches on opus and does not cache on haiku" do
      short = [tools: String.duplicate("x", 3_000)]

      capture_log(fn ->
        assert Prefix.build("opus-5", short).cacheable
        refute Prefix.build("haiku-4.5", short).cacheable
      end)
    end
  end

  describe "token estimate" do
    test "is an estimate, declared as such" do
      assert Prefix.estimate_tokens(String.duplicate("a", 400)) == 100
    end

    test "empty text estimates zero" do
      assert Prefix.estimate_tokens("") == 0
    end
  end
end
