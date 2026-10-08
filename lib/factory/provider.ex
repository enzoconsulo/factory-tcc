defmodule Factory.Provider do
  @moduledoc """
  The boundary between the factory's governance and the model vendor. Gates, the cycle limit
  and per-turn accounting work the same behind this contract, whoever answers on the other
  side.
  """

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
end
