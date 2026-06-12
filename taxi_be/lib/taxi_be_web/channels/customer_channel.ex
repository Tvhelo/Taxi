defmodule TaxiBeWeb.CustomerChannel do
  use TaxiBeWeb, :channel

  require Logger

  @impl true
  def join("customer:" <> username, _payload, socket) do
    Logger.info("Customer #{username} joined customer channel")
    {:ok, socket}
  end
end
