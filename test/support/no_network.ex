defmodule Factory.NoNetwork do
  @moduledoc """
  The Plug that `Req` uses by default in the test suite: it RAISES instead of answering.

  A request reaching it is one a test forgot to stub; answering something plausible would
  hide that. It is a config-level Plug rather than `Req.Test.stub/2` because stubs belong to
  the calling process and the suite runs `async: true`.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    raise """
    an HTTP request tried to LEAVE during the test suite: #{conn.method} #{conn.host}#{conn.request_path}

    The suite runs without network. Stub the call in the test itself by passing `plug:` to
    the request:

        Req.get!(url, plug: fn conn -> Req.Test.json(conn, response) end)
    """
  end
end
