defmodule TaxiBeWeb.StatusController do
  use TaxiBeWeb, :controller

  def index(conn, _params) do
    json(conn, %{
      app: "Taxi 24 backend",
      status: "ok",
      frontend_url: "http://localhost:3000",
      api: %{
        create_booking: "POST /api/bookings",
        reply_booking: "POST /api/bookings/:id",
        cancel_booking: "POST /api/bookings/:id/cancel"
      },
      websocket: "/socket"
    })
  end
end
