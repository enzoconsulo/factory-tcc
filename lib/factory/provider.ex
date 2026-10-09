defmodule Factory.Provider do
  @moduledoc """
  The boundary between the factory's governance and the model vendor. Gates, the cycle limit
  and per-turn accounting work the same behind this contract, whoever answers on the other
  side.

  Adapters:

    * `Factory.Provider.Fake` — deterministic double, no network, no cost (used by tests).

  The contract is a single synchronous function for ONE turn. Repeating, counting turns and
  deciding to stop belong to the agent loop, not to the adapter.
  """

  alias Factory.Provider.Request
  alias Factory.Provider.Response
  alias Factory.Provider.Usage

  @doc """
  Performs ONE turn: sends the request and returns the response with that turn's usage.

  Returns `{:error, term}` instead of raising: the loop must tell quota from refusal from
  network failure.

  When a session already spent tokens before failing (e.g. `:timeout` or
  `:outside_confinement` after real model turns), the adapter wraps the reason as
  `{:error, {:with_usage, reason, %Usage{}}}` so the loop can record the cost. The quota wall
  (`{:error, {:quota, reopens_at}}`) is never wrapped.
  """
  @callback chat(request :: Request.t(), opts :: keyword()) ::
              {:ok, Response.t()}
              | {:error, {:with_usage, reason :: term(), Usage.t()}}
              | {:error, term()}

  @doc """
  The adapter's family:

    * `:full_agent` — the adapter runs its own tool loop and permissions (e.g.
      `claude --print`); the factory sends ONE request and executes no tools;
    * `:model_endpoint` — the adapter only talks to the model; the factory executes the
      tools and governs the loop.

  Optional; resolve it with `Factory.Provider.family/1`, which applies the default.
  """
  @callback family() :: :full_agent | :model_endpoint

  @optional_callbacks family: 0

  @doc "The configured provider, or `Factory.Provider.Fake` (the default used by the suite)."
  @spec configured() :: module()
  def configured do
    Application.get_env(:factory, :provider, Factory.Provider.Fake)
  end

  @doc """
  The family of the given adapter, defaulting to `:model_endpoint`. An adapter that does not
  declare `family/0` falls on the strict path, where the factory's confinement and budget
  apply: failing towards safety.
  """
  @spec family(module()) :: :full_agent | :model_endpoint
  def family(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :family, 0) do
      module.family()
    else
      :model_endpoint
    end
  end

  @doc "Chats with the configured provider."
  @spec chat(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def chat(request, opts \\ []) do
    configured().chat(request, opts)
  end

  defmodule Block do
    @moduledoc """
    A prompt-prefix block. `cache_breakpoint: true` tells the adapter that this block closes
    a stable segment. The mark lives in the request so prefix bytes can be tested without
    network.
    """

    @type t :: %__MODULE__{text: String.t(), cache_breakpoint: boolean()}

    defstruct text: "", cache_breakpoint: false
  end

  defmodule Usage do
    @moduledoc """
    What ONE turn consumed: the same numbers as the `usages` table. The split between
    input, cache read and cache write is mandatory, never a single total.
    """

    @type t :: %__MODULE__{
            input_tokens: non_neg_integer(),
            cache_write_tokens: non_neg_integer(),
            cache_read_tokens: non_neg_integer(),
            output_tokens: non_neg_integer(),
            duration_ms: non_neg_integer() | nil,
            cache_ttl: :no_cache | :five_minutes | :one_hour
          }

    defstruct input_tokens: 0,
              cache_write_tokens: 0,
              cache_read_tokens: 0,
              output_tokens: 0,
              duration_ms: nil,
              cache_ttl: :no_cache
  end

  defmodule Request do
    @moduledoc """
    Everything an adapter needs for one turn.

    `prefix` is the stable part (tools, role doctrine, project index), in blocks ordered from
    most to least stable; `messages` is the conversation history. Editing the prefix
    invalidates the cache for everything after it.
    """

    alias Factory.Provider.Block

    @type message :: %{role: :user | :assistant | :system, content: term()}

    @type t :: %__MODULE__{
            model: String.t(),
            role: String.t(),
            prefix: [Block.t()],
            messages: [message()],
            tools: [map()],
            max_turns: pos_integer()
          }

    defstruct model: "haiku-4.5",
              role: "builder",
              prefix: [],
              messages: [],
              tools: [],
              max_turns: 30
  end

  defmodule Response do
    @moduledoc """
    What came back from ONE turn.

    The loop reads `stop_reason` to decide whether to repeat: `:tool_use` means there is work
    to do before the next turn; the others end it. `:max_tokens` and `:max_turns` are the
    same budget overrun reported by different families: `:max_tokens` by a `:model_endpoint`
    adapter, `:max_turns` by a `:full_agent` adapter.
    """

    alias Factory.Provider.Usage

    @type stop_reason ::
            :end_turn
            | :tool_use
            | :max_tokens
            | :max_turns
            | :refusal

    @type t :: %__MODULE__{
            blocks: [map()],
            stop_reason: stop_reason(),
            usage: Usage.t()
          }

    defstruct blocks: [], stop_reason: :end_turn, usage: %Usage{}
  end
end
