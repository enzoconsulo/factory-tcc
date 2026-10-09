defmodule Factory.Cost.PricingTest do
  @moduledoc """
  Locks the cost arithmetic and, above all, the BREAKDOWN: a single total would hide the
  share of the input bill carried by cache writes.
  """

  use ExUnit.Case, async: true

  alias Factory.Cost.Pricing
  alias Factory.Cost.Usage, as: Cost
  alias Factory.Provider.Usage

  defp usage(opts \\ []) do
    %Usage{
      input_tokens: Keyword.get(opts, :input, 0),
      cache_write_tokens: Keyword.get(opts, :write, 0),
      cache_read_tokens: Keyword.get(opts, :read, 0),
      output_tokens: Keyword.get(opts, :output, 0),
      cache_ttl: Keyword.get(opts, :ttl, :one_hour),
      duration_ms: Keyword.get(opts, :duration_ms, 10)
    }
  end

  describe "price table" do
    test "carries the date it was checked" do
      assert %Date{} = Pricing.checked_on()
    end

    test "the three planned models are priced" do
      assert Enum.sort(Pricing.models()) == ["haiku-4.5", "opus-5", "sonnet-5"]
    end

    test "the CLI's long ids map to the same row" do
      assert Pricing.price("claude-haiku-4-5-20251001") == Pricing.price("haiku-4.5")
      assert Pricing.price("claude-sonnet-5") == Pricing.price("sonnet-5")
    end
  end

  describe "the ids the CLI currently returns" do
    for {id, internal} <- [
          {"claude-sonnet-5-5", "sonnet-5"},
          {"claude-opus-5-5", "opus-5"},
          {"claude-haiku-4-5-20251001", "haiku-4.5"}
        ] do
      @id id
      @internal internal

      test "#{id} is priced on the #{internal} row" do
        u = usage(input: 1_000, write: 2_000, read: 30_000, output: 400)

        assert Pricing.price(@id) != nil
        assert Pricing.price(@id) == Pricing.price(@internal)
        assert Pricing.estimate(@id, u) == Pricing.estimate(@internal, u)
      end
    end

    test "summarizing turns with the real ids reports no unpriced model" do
      turns =
        for id <- ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-4-5-20251001"],
            do: {id, usage(input: 1_000)}

      assert {:ok, %{turns: 3}} = Pricing.summarize(turns)
    end
  end

  describe "estimating one turn" do
    test "full-price input: 1M opus tokens cost the table's 5 dollars" do
      {:ok, r} = Pricing.estimate("opus-5", usage(input: 1_000_000))

      assert r.full_input_usd == 5.0
      assert r.total_usd == 5.0
    end

    test "output uses the output price" do
      {:ok, r} = Pricing.estimate("opus-5", usage(output: 1_000_000))
      assert r.output_usd == 25.0
    end

    test "cache reads cost 0.1x input" do
      {:ok, r} = Pricing.estimate("opus-5", usage(read: 1_000_000))

      assert r.cache_read_usd == 0.5
      assert r.full_input_usd == 0.0
    end

    test "cache writes with a 1-hour TTL cost 2.0x input" do
      {:ok, r} = Pricing.estimate("opus-5", usage(write: 1_000_000, ttl: :one_hour))
      assert r.cache_write_usd == 10.0
    end

    test "cache writes with a 5-minute TTL cost 1.25x input" do
      {:ok, r} = Pricing.estimate("opus-5", usage(write: 1_000_000, ttl: :five_minutes))
      assert r.cache_write_usd == 6.25
    end

    test "the turn's TTL decides the multiplier" do
      assert Pricing.write_multiplier(usage(ttl: :one_hour)) == 2.0
      assert Pricing.write_multiplier(usage(ttl: :five_minutes)) == 1.25
    end

    test "haiku input is five times cheaper than opus" do
      {:ok, opus} = Pricing.estimate("opus-5", usage(input: 1_000_000))
      {:ok, haiku} = Pricing.estimate("haiku-4.5", usage(input: 1_000_000))

      assert opus.full_input_usd / haiku.full_input_usd == 5.0
    end

    test "a turn with all four parts sums to the total" do
      {:ok, r} =
        Pricing.estimate(
          "sonnet-5",
          usage(input: 1_000_000, read: 1_000_000, write: 1_000_000, output: 1_000_000)
        )

      # input 2.00 + read 0.20 + write 4.00 (2.0x) + output 10.00
      assert r.full_input_usd == 2.0
      assert r.cache_read_usd == 0.2
      assert r.cache_write_usd == 4.0
      assert r.output_usd == 10.0
      assert r.total_usd == 16.2
    end

    test "zero usage costs zero" do
      {:ok, r} = Pricing.estimate("haiku-4.5", usage())
      assert r.total_usd == 0.0
    end
  end

  describe "unknown model" do
    test "returns a named error instead of silently counting zero" do
      assert {:error, :unpriced_model} =
               Pricing.estimate("model-that-does-not-exist", usage(input: 1_000))
    end

    test "a silent zero would vanish from the total, so the contract is an error" do
      {:error, reason} = Pricing.estimate("gpt-invention", usage(input: 10_000_000))
      assert reason == :unpriced_model
    end

    test "summarize also refuses, naming WHICH models are missing" do
      turns = [
        {"opus-5", usage(input: 100)},
        {"model-a", usage(input: 100)},
        {"model-b", usage(input: 100)}
      ]

      assert {:error, {:unpriced_model, ["model-a", "model-b"]}} = Pricing.summarize(turns)
    end
  end

  describe "summary: the breakdown, not only the total" do
    test "returns the four parts separately" do
      turns = [
        {"sonnet-5", usage(input: 1_000_000)},
        {"sonnet-5", usage(read: 1_000_000)},
        {"sonnet-5", usage(write: 1_000_000, ttl: :one_hour)},
        {"sonnet-5", usage(output: 1_000_000)}
      ]

      {:ok, r} = Pricing.summarize(turns)

      assert r.full_input_usd == 2.0
      assert r.cache_read_usd == 0.2
      assert r.cache_write_usd == 4.0
      assert r.output_usd == 10.0
      assert r.total_usd == 16.2
      assert r.turns == 4
    end

    test "exposes the share of the input bill carried by cache writes" do
      turns = [
        {"sonnet-5", usage(input: 0, read: 1_000_000, write: 100_000)}
      ]

      {:ok, r} = Pricing.summarize(turns)

      # read 0.20 · write 0.40 → total input 0.60, writes are 2/3 of it
      assert r.total_input_usd == 0.6
      assert r.cache_write_share_of_input == 0.6667
    end

    test "few write tokens can carry most of the input bill" do
      turns = [{"sonnet-5", usage(read: 933_400, write: 66_600, ttl: :one_hour)}]

      {:ok, r} = Pricing.summarize(turns)

      token_share = 66_600 / 1_000_000
      assert_in_delta token_share, 0.0666, 0.001
      assert r.cache_write_share_of_input > 0.4, "writes must dominate the input bill"
    end

    test "an empty list summarizes to zeros" do
      {:ok, r} = Pricing.summarize([])

      assert r.total_usd == 0.0
      assert r.turns == 0
      assert r.cache_write_share_of_input == 0.0
    end

    test "different models in one sum are each priced by their own row" do
      turns = [
        {"opus-5", usage(input: 1_000_000)},
        {"haiku-4.5", usage(input: 1_000_000)}
      ]

      {:ok, r} = Pricing.summarize(turns)
      assert r.full_input_usd == 6.0
    end
  end

  describe "the second unit: quota" do
    test "quota is counted even where dollars are an estimate" do
      assert Pricing.quota_units("haiku-4.5", usage(input: 1_000)) == 1.0
    end

    test "opus weighs five times haiku in quota" do
      u = usage(input: 1_000)
      assert Pricing.quota_units("opus-5", u) / Pricing.quota_units("haiku-4.5", u) == 5.0
    end

    test "cache reads also weigh 0.1x in quota" do
      assert Pricing.quota_units("haiku-4.5", usage(read: 10_000)) == 1.0
    end

    test "a model without a declared weight does not zero the quota" do
      assert Pricing.quota_units("new-model", usage(input: 1_000)) == 1.0
    end

    test "the estimate returns both units together" do
      {:ok, r} = Pricing.estimate("sonnet-5", usage(input: 1_000))

      assert r.total_usd > 0.0
      assert r.quota_units == 2.0
    end
  end

  describe "the CLI's short aliases are priced" do
    # An unpriced alias would count as zero cost per turn.
    for {alias_name, internal} <- [
          {"sonnet", "sonnet-5"},
          {"opus", "opus-5"},
          {"haiku", "haiku-4.5"}
        ] do
      @alias_name alias_name
      @internal internal

      test "#{alias_name} maps to the #{internal} row" do
        u = usage(input: 1_000, write: 2_000, read: 30_000, output: 400)

        assert Pricing.price(@alias_name) == Pricing.price(@internal)
        assert Pricing.estimate(@alias_name, u) == Pricing.estimate(@internal, u)
      end
    end
  end

  describe "bridge to the database row" do
    test "converts reported usage into `usages` attributes" do
      {:ok, attrs} =
        Cost.to_record("sonnet-5", usage(input: 1_000, read: 9_000, output: 500),
          dispatch_id: 7,
          turn: 3
        )

      assert attrs.dispatch_id == 7
      assert attrs.turn == 3
      assert attrs.input_tokens == 1_000
      assert attrs.cache_read_tokens == 9_000
      assert Decimal.gt?(attrs.cost_usd, 0)
      assert Decimal.gt?(attrs.quota_units, 0)
    end

    test "turn and dispatch come from OUTSIDE, because they belong to the system" do
      assert_raise KeyError, fn ->
        Cost.to_record("sonnet-5", usage(), dispatch_id: 1)
      end
    end

    test "an unpriced model prevents the write instead of recording zero" do
      assert {:error, :unpriced_model} =
               Cost.to_record("does-not-exist", usage(), dispatch_id: 1, turn: 1)
    end

    test "sums tokens without touching prices" do
      sum = Cost.sum_tokens([usage(input: 10, read: 90), usage(input: 5)])

      assert sum.input_tokens == 15
      assert sum.cache_read_tokens == 90
      assert sum.turns == 2
    end

    test "the read:write ratio summarizes whether the cache is working" do
      turns = [usage(read: 1_400_000, write: 100_000)]
      assert Cost.cache_ratio(turns) == 14.0
    end

    test "without any write the ratio is nil, not a division by zero" do
      assert Cost.cache_ratio([usage(read: 100)]) == nil
    end
  end
end
