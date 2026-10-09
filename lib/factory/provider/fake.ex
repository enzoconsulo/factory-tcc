defmodule Factory.Provider.Fake do
  @moduledoc """
  The deterministic double. It answers from a SCRIPT declared by the test, so the whole
  suite runs without network, quota or API key. It has no path to the network or to
  credentials, and a test fails if this file references any HTTP module.

  The script is a list of `Response`s delivered in order. When exhausted it returns
  `{:error, :script_exhausted}`; it never hangs and never invents an answer.

      {:ok, needle} = Fake.start(script: [response_a, response_b])
      {:ok, response} = Fake.chat(request, needle: needle)
  """

  @behaviour Factory.Provider

  alias Factory.Provider.Request
  alias Factory.Provider.Response
  alias Factory.Provider.Usage

  use Agent

  @doc """
  Starts a script and returns the needle pointing to the next response. Each test has its
  own, so async tests do not share state.
  """
  @spec start(keyword()) :: {:ok, pid()}
  def start(opts \\ []) do
    script = Keyword.get(opts, :script, [])
    Agent.start_link(fn -> %{script: script, seen: [], seen_options: []} end)
  end

  @doc "The requests the double received, in order."
  @spec seen(pid()) :: [Request.t()]
  def seen(needle) do
    Agent.get(needle, fn state -> Enum.reverse(state.seen) end)
  end

  @doc """
  The options of each call, in the same order as `seen/1`, so a test can check what was
  passed outside the request (such as `root`).
  """
  @spec seen_options(pid()) :: [keyword()]
  def seen_options(needle) do
    Agent.get(needle, fn state -> Enum.reverse(state.seen_options) end)
  end

  @doc "Builds a plausible `Response`, with usage that exercises the cache split."
  @spec response(keyword()) :: Response.t()
  def response(opts \\ []) do
    %Response{
      blocks: Keyword.get(opts, :blocks, [%{type: :text, text: "done"}]),
      stop_reason: Keyword.get(opts, :stop_reason, :end_turn),
      usage: %Usage{
        input_tokens: Keyword.get(opts, :input_tokens, 120),
        cache_write_tokens: Keyword.get(opts, :cache_write_tokens, 0),
        cache_read_tokens: Keyword.get(opts, :cache_read_tokens, 4_800),
        output_tokens: Keyword.get(opts, :output_tokens, 210),
        duration_ms: Keyword.get(opts, :duration_ms, 42),
        cache_ttl: Keyword.get(opts, :cache_ttl, :one_hour)
      }
    }
  end

  # No default argument: it would also define `chat/1`, which is not a callback. The default
  # lives in `Factory.Provider.chat/2`.
  @impl Factory.Provider
  def chat(%Request{} = request, opts) do
    case Keyword.fetch(opts, :needle) do
      {:ok, needle} -> next(needle, request, opts)
      :error -> {:error, :no_script}
    end
  end

  defp next(needle, request, opts) do
    Agent.get_and_update(needle, fn state ->
      state = %{
        state
        | seen: [request | state.seen],
          seen_options: [opts | state.seen_options]
      }

      case state.script do
        [%Response{} = next | rest] -> {{:ok, next}, %{state | script: rest}}
        [] -> {{:error, :script_exhausted}, state}
      end
    end)
  end
end
