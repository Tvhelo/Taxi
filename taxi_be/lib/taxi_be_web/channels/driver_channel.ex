defmodule TaxiBeWeb.DriverChannel do
  use TaxiBeWeb, :channel

  require Logger

  @impl true
  def join("driver:" <> username, _payload, socket) do
    Logger.info("Driver #{username} joined driver channel")
    {:ok, socket}
  end
end
