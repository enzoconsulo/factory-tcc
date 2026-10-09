defmodule Factory.Provider.FakeTest do
  @moduledoc """
  Locks the double and, with it, the offline guarantee of the suite. The test asserting that
  the fake references no HTTP module checks an impossibility rather than a behaviour.
  """

  use ExUnit.Case, async: true

  alias Factory.Provider
  alias Factory.Provider.Fake
  alias Factory.Provider.Request
  alias Factory.Provider.Response
  alias Factory.Provider.Usage

  defp request(attrs \\ %{}) do
    struct(
      %Request{model: "haiku-4.5", messages: [%{role: :user, content: "hi"}]},
      attrs
    )
  end

  describe "script" do
    test "returns the responses in the declared order" do
      first = Fake.response(blocks: [%{type: :text, text: "one"}])
      second = Fake.response(blocks: [%{type: :text, text: "two"}])

      {:ok, needle} = Fake.start(script: [first, second])

      assert {:ok, %Response{blocks: [%{text: "one"}]}} =
               Fake.chat(request(), needle: needle)

      assert {:ok, %Response{blocks: [%{text: "two"}]}} =
               Fake.chat(request(), needle: needle)
    end

    test "an exhausted script returns {:error, :script_exhausted} without hanging or inventing" do
      {:ok, needle} = Fake.start(script: [Fake.response()])

      assert {:ok, %Response{}} = Fake.chat(request(), needle: needle)
      assert {:error, :script_exhausted} = Fake.chat(request(), needle: needle)

      # and keeps returning the same error
      assert {:error, :script_exhausted} = Fake.chat(request(), needle: needle)
    end

    test "an empty script starts exhausted" do
      {:ok, needle} = Fake.start()
      assert {:error, :script_exhausted} = Fake.chat(request(), needle: needle)
    end

    test "without a needle, returns an error instead of guessing" do
      assert {:error, :no_script} = Fake.chat(request(), [])
    end

    test "two needles do not interfere: each test has its own" do
      {:ok, one} = Fake.start(script: [Fake.response(blocks: [%{text: "A"}])])
      {:ok, other} = Fake.start(script: [Fake.response(blocks: [%{text: "B"}])])

      assert {:ok, %Response{blocks: [%{text: "A"}]}} =
               Fake.chat(request(), needle: one)

      assert {:ok, %Response{blocks: [%{text: "B"}]}} =
               Fake.chat(request(), needle: other)
    end

    test "records the received requests, so a test can check what was built" do
      {:ok, needle} = Fake.start(script: [Fake.response(), Fake.response()])

      Fake.chat(request(%{model: "opus-5"}), needle: needle)
      Fake.chat(request(%{model: "sonnet-5"}), needle: needle)

      assert [%Request{model: "opus-5"}, %Request{model: "sonnet-5"}] =
               Fake.seen(needle)
    end

    test "records each call's OPTIONS in the same order, not only the request" do
      {:ok, needle} = Fake.start(script: [Fake.response(), Fake.response()])

      Fake.chat(request(), needle: needle, root: "C:/projects/target")
      Fake.chat(request(), needle: needle, root: "C:/projects/other")

      [first, second] = Fake.seen_options(needle)

      assert Keyword.get(first, :root) == "C:/projects/target"
      assert Keyword.get(second, :root) == "C:/projects/other"
    end
  end

  describe "usage" do
    test "returns one Usage per turn, with the cache split filled in" do
      {:ok, needle} = Fake.start(script: [Fake.response()])

      {:ok, %Response{usage: usage}} = Fake.chat(request(), needle: needle)

      assert %Usage{} = usage
      assert usage.input_tokens > 0
      assert usage.cache_read_tokens > 0
      assert usage.output_tokens > 0
      assert usage.cache_ttl in [:no_cache, :five_minutes, :one_hour]
    end

    test "cache numbers are adjustable through the script" do
      response =
        Fake.response(
          input_tokens: 10,
          cache_write_tokens: 5_000,
          cache_read_tokens: 0,
          output_tokens: 7,
          cache_ttl: :five_minutes
        )

      {:ok, needle} = Fake.start(script: [response])
      {:ok, %Response{usage: usage}} = Fake.chat(request(), needle: needle)

      assert usage.cache_write_tokens == 5_000
      assert usage.cache_read_tokens == 0
      assert usage.cache_ttl == :five_minutes
    end

    test "stop_reason follows the script" do
      {:ok, needle} =
        Fake.start(script: [Fake.response(stop_reason: :tool_use)])

      assert {:ok, %Response{stop_reason: :tool_use}} =
               Fake.chat(request(), needle: needle)
    end
  end

  describe "the contract" do
    test "Fake implements the Factory.Provider behaviour" do
      behaviours =
        Fake.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Factory.Provider in behaviours
    end

    test "the behaviour declares chat/2" do
      assert {:chat, 2} in Factory.Provider.behaviour_info(:callbacks)
    end

    test "the provider configured for the suite is Fake" do
      assert Provider.configured() == Fake
    end
  end

  describe "no network" do
    @forbidden ~w[
      httpc hackney gun ibrowse
      Req Finch Mint HTTPoison Tesla ssl inets
    ]

    test "Fake's code references no HTTP module" do
      source = File.read!("lib/factory/provider/fake.ex")

      # Whole words, not substrings (`Request` contains "Req").
      for forbidden <- @forbidden do
        pattern = ~r/(?<![A-Za-z0-9_.])#{Regex.escape(forbidden)}(?![A-Za-z0-9_])/

        refute Regex.match?(pattern, source),
               "Provider.Fake references #{forbidden}; it exists precisely NOT to touch " <>
                 "the network."
      end
    end

    test "the detector itself recognizes a real reference" do
      pattern = ~r/(?<![A-Za-z0-9_.])Req(?![A-Za-z0-9_])/

      assert Regex.match?(pattern, "Req.get!(url)")
      refute Regex.match?(pattern, "%Request{}")
      refute Regex.match?(pattern, "alias Factory.Provider.Request")
    end

    test "Fake reads no environment variable" do
      source = File.read!("lib/factory/provider/fake.ex")

      refute String.contains?(source, "System.get_env")
      refute String.contains?(source, "ANTHROPIC")
      refute String.contains?(source, "API_KEY")
    end

    test "using Fake involves no HTTP module" do
      {:ok, needle} = Fake.start(script: [Fake.response()])
      assert {:ok, _} = Fake.chat(request(), needle: needle)

      # `Req` is a dependency; what matters is that Fake's source never
      # references it. The suite-wide network block is checked in the E2 milestone test.
      source = File.read!("lib/factory/provider/fake.ex")
      pattern = ~r/(?<![A-Za-z0-9_.])Req(?![A-Za-z0-9_])/

      refute Regex.match?(pattern, source)
    end
  end
end
