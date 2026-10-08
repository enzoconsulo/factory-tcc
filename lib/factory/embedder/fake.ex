defmodule Factory.Embedder.Fake do
  @moduledoc """
  Deterministic hash vectors: no model, no network, no cost. The test suite uses it wherever
  an embedding is needed. Two properties matter and are tested: the same text always yields
  the same vector, and different texts yield different vectors. There is no semantics:
  similar texts do not produce close vectors.

  The default of 384 dimensions matches small sentence-transformer models. It is
  configurable so callers can be exercised at another dimension.

      config :factory, Factory.Embedder.Fake, dimensions: 768
  """

  @behaviour Factory.Embedder

  @default_dimensions 384

  @impl Factory.Embedder
  def dimensions do
    :factory
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:dimensions, @default_dimensions)
  end

  @impl Factory.Embedder
  def embed(texts) when is_list(texts) do
    if Enum.all?(texts, &is_binary/1) do
      {:ok, Enum.map(texts, &vector/1)}
    else
      {:error, :text_not_a_string}
    end
  end

  def embed(_other), do: {:error, :expected_list}

  @doc """
  The vector of ONE text: deterministic, normalized, with `dimensions/0` positions. Each
  position derives from a hash of the whole text combined with the position index.
  """
  @spec vector(String.t()) :: [float()]
  def vector(text) when is_binary(text) do
    seed = :erlang.phash2(text, 4_294_967_296)

    0..(dimensions() - 1)
    |> Enum.map(fn position ->
      :erlang.phash2({seed, position}, 2_000_001) / 1_000_000.0 - 1.0
    end)
    |> normalize()
  end

  # Unit vectors make cosine distance comparable across any pair. A numeric guard
  # is used because matching `0.0` only matches `+0.0` since OTP 27.
  defp normalize(vector) do
    norm = :math.sqrt(Enum.reduce(vector, 0.0, fn value, sum -> sum + value * value end))

    if norm > 0 do
      Enum.map(vector, &(&1 / norm))
    else
      vector
    end
  end
end
