defmodule Factory.Agents.Loop do
  @moduledoc """
  The core of the system: the tool-use loop, as a supervised process.

  Builds the request, calls the provider, runs the requested tools and repeats, until the
  model says it is done or a cap imposed from outside is hit. Four rules:

  1. All tool results go back in a single turn, so the model keeps requesting tools in
     parallel.
  2. The caps are process state (`Factory.Agents.State`), not prompt text.
  3. A failing tool returns a result with `error: true`; it never disappears, or the model
     would be blind to what happened.
  4. Each turn records its usage BEFORE the loop decides to continue. This also holds for a
     provider error that already spent tokens: the provider returns
     `{:error, {:with_usage, reason, usage}}` and the usage is recorded before the loop ends
     with `:error`.

  On a provider error the outcome is `:error`; the raw error term is kept in `error_reason` of
  the summary so callers can tell a wall (quota, sandbox) from a work error.

  It is a GenServer so it can be killed from outside cleanly and supervised.
  """

  use GenServer

  require Logger

  alias Factory.Agents.State
  alias Factory.Cost.Pricing
  alias Factory.Provider
  alias Factory.Provider.Request
  alias Factory.Provider.Response
  alias Factory.Provider.Usage

  @tool_concurrency 4
  @tool_timeout :timer.minutes(2)

  @doc """
  Runs the loop to the end and returns the summary. Synchronous.

  The call timeout is `:infinity` on purpose: the real limits are the caps in the state, and
  a short timeout would kill the loop mid-way and lose the record of what was spent.

  `opts` are those of `Factory.Agents.State.new/1`.
  """
  @spec run(keyword()) :: {:ok, map()}
  def run(opts) do
    {:ok, pid} = GenServer.start_link(__MODULE__, opts)
    GenServer.call(pid, :run, :infinity)
  end

  @impl GenServer
  def init(opts) do
    {:ok, State.new(opts)}
  end

  @impl GenServer
  def handle_call(:run, _from, state) do
    final = loop(state)
    {:stop, :normal, {:ok, State.summary(final)}, final}
  end

  defp loop(state) do
    module = state.provider || Provider.configured()
    family = Provider.family(module)

    # `tools` reach a `:full_agent` provider too: `ClaudeCLI` serves them to the CLI over MCP,
    # so its actions run through the same bound functions as this loop's own.
    case module.chat(request(state, family),
           needle: state.needle,
           root: state.root,
           tools: state.tools
         ) do
      {:ok, response} ->
        handle_response(family, state, response)

      {:error, {:with_usage, reason, %Usage{} = usage}} ->
        Logger.warning(
          "loop stopped by provider error: #{inspect(reason)} (measured usage recorded)"
        )

        state
        |> record_usage(usage, 0)
        |> Map.put(:outcome, :error)
        |> Map.put(:error_reason, reason)

      {:error, reason} ->
        Logger.warning("loop stopped by provider error: #{inspect(reason)}")
        %{state | outcome: :error, error_reason: reason}
    end
  end

  # :full_agent family: the provider already executed its tools. `:tool_use` blocks are a
  # record of what it did, not requests for the loop. One turn, one outcome.
  defp handle_response(:full_agent, state, %Response{} = response) do
    state
    |> record_usage(response)
    |> Map.put(:outcome, response.stop_reason)
  end

  defp handle_response(:model_endpoint, state, %Response{stop_reason: :tool_use} = response) do
    state
    |> apply_turn(response)
    |> continue_or_stop()
  end

  defp handle_response(:model_endpoint, state, %Response{stop_reason: reason} = response) do
    state
    |> record_usage(response)
    |> Map.put(:outcome, reason)
  end

  defp continue_or_stop(state) do
    case State.check_continue(state) do
      :ok -> loop(state)
      {:stop, outcome} -> %{state | outcome: outcome}
    end
  end

  # Rule 4: record usage BEFORE appending and deciding.
  defp apply_turn(state, %Response{} = response) do
    state
    |> record_usage(response)
    |> State.append_turn(response.blocks, run_tools(state, response.blocks))
  end

  defp record_usage(state, %Response{usage: usage, blocks: blocks}) do
    # Counts `:tool_use` blocks, not executed tools, so the count means the same in both
    # families.
    calls = Enum.count(blocks, &(&1[:type] == :tool_use))

    record_usage(state, usage, calls)
  end

  defp record_usage(state, %Usage{} = usage, calls) do
    cost =
      case Pricing.estimate(state.model, usage) do
        {:ok, %{total_usd: total}} -> total
        # An unpriced model does not stop the loop: the dollar figure is only an estimate.
        {:error, :unpriced_model} -> 0.0
      end

    State.record_usage(state, usage, cost, calls)
  end

  # All tool requests of the turn run in parallel and their results come back together.
  # `on_timeout: :kill_task` turns a stuck tool into an error result.
  defp run_tools(state, blocks) do
    blocks
    |> Enum.filter(&(&1[:type] == :tool_use))
    |> Task.async_stream(&run_one(state, &1),
      max_concurrency: @tool_concurrency,
      timeout: @tool_timeout,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.map(&result_or_error/1)
  end

  defp run_one(state, block) do
    case Map.fetch(state.tools, block[:name]) do
      {:ok, function} ->
        %{
          type: :tool_result,
          id: block[:id],
          name: block[:name],
          content: function.(block[:arguments] || %{}, state.root),
          error: false
        }

      :error ->
        %{
          type: :tool_result,
          id: block[:id],
          name: block[:name],
          content: "unknown tool: #{inspect(block[:name])}",
          error: true
        }
    end
  rescue
    exception ->
      # Rule 3: a raising tool becomes an error result; it never disappears.
      %{
        type: :tool_result,
        id: block[:id],
        name: block[:name],
        content: "the tool raised: #{Exception.message(exception)}",
        error: true
      }
  end

  defp result_or_error({:ok, result}), do: result

  defp result_or_error({:exit, {block, reason}}) do
    %{
      type: :tool_result,
      id: block[:id],
      name: block[:name],
      content: "the tool did not finish: #{inspect(reason)}",
      error: true
    }
  end

  defp result_or_error({:exit, reason}) do
    %{
      type: :tool_result,
      id: nil,
      name: nil,
      content: "the tool did not finish: #{inspect(reason)}",
      error: true
    }
  end

  defp request(state, family) do
    %Request{
      model: state.model,
      role: state.role,
      vocabulary: state.vocabulary,
      messages: state.messages,
      tools: request_tools(family, state),
      max_turns: state.max_turns
    }
  end

  # The full_agent family runs its own tool loop: the factory's tool list means nothing to it.
  defp request_tools(:full_agent, _state), do: []
  defp request_tools(:model_endpoint, state), do: Map.keys(state.tools)
end
