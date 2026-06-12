defmodule TaxiBeWeb.BookingControllerTest do
  use TaxiBeWeb.ConnCase

  @booking_params %{
    "pickup_address" => "Tecnologico de Monterrey, campus Puebla, Mexico",
    "dropoff_address" => "Triangulo Las Animas, Puebla, Mexico",
    "username" => "luciano"
  }

  test "creates a booking and accepts the selected driver", %{conn: conn} do
    Phoenix.PubSub.subscribe(TaxiBe.PubSub, "customer:luciano")
    Phoenix.PubSub.subscribe(TaxiBe.PubSub, "driver:frodo")

    conn = post(conn, ~p"/api/bookings", @booking_params)
    response = json_response(conn, 201)
    booking_id = response["booking_id"]

    assert response["msg"] == "Estamos procesando tu solicitud."

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:luciano",
      event: "booking_request",
      payload: %{booking_id: ^booking_id, status: "searching"}
    }

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "driver:frodo",
      event: "booking_request",
      payload: %{booking_id: ^booking_id, status: "requested"}
    }

    conn =
      build_conn()
      |> post(~p"/api/bookings/#{booking_id}", %{action: "accept", username: "frodo"})

    assert %{
             "driver" => "frodo",
             "eta_minutes" => 5,
             "status" => "accepted"
           } = json_response(conn, 200)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:luciano",
      event: "booking_request",
      payload: %{booking_id: ^booking_id, status: "accepted", eta_minutes: 5}
    }
  end

  test "notifies the customer when the selected driver rejects", %{conn: conn} do
    Phoenix.PubSub.subscribe(TaxiBe.PubSub, "customer:luciano")
    Phoenix.PubSub.subscribe(TaxiBe.PubSub, "driver:frodo")

    conn = post(conn, ~p"/api/bookings", @booking_params)
    booking_id = json_response(conn, 201)["booking_id"]

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:luciano",
      event: "booking_request",
      payload: %{booking_id: ^booking_id, status: "searching"}
    }

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "driver:frodo",
      event: "booking_request",
      payload: %{booking_id: ^booking_id, status: "requested"}
    }

    conn =
      build_conn()
      |> post(~p"/api/bookings/#{booking_id}", %{action: "reject", username: "frodo"})

    assert %{"status" => "rejected"} = json_response(conn, 200)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:luciano",
      event: "booking_request",
      payload: %{booking_id: ^booking_id, status: "no_driver"}
    }
  end

  test "rejects booking creation when required fields are missing", %{conn: conn} do
    conn = post(conn, ~p"/api/bookings", %{"username" => "luciano"})

    assert %{"msg" => msg} = json_response(conn, 400)
    assert msg =~ "pickup_address"
  end

  test "rejects replies from a driver that was not contacted", %{conn: conn} do
    conn = post(conn, ~p"/api/bookings", @booking_params)
    booking_id = json_response(conn, 201)["booking_id"]

    conn =
      build_conn()
      |> post(~p"/api/bookings/#{booking_id}", %{action: "accept", username: "merry"})

    assert %{"msg" => "Este conductor no tiene asignada la reservacion."} =
             json_response(conn, 409)
  end

  test "lets the booking customer cancel an active request", %{conn: conn} do
    Phoenix.PubSub.subscribe(TaxiBe.PubSub, "customer:luciano")
    Phoenix.PubSub.subscribe(TaxiBe.PubSub, "driver:frodo")

    conn = post(conn, ~p"/api/bookings", @booking_params)
    booking_id = json_response(conn, 201)["booking_id"]

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:luciano",
      event: "booking_request",
      payload: %{booking_id: ^booking_id, status: "searching"}
    }

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "driver:frodo",
      event: "booking_request",
      payload: %{booking_id: ^booking_id, status: "requested"}
    }

    conn =
      build_conn()
      |> post(~p"/api/bookings/#{booking_id}", %{action: "cancel", username: "luciano"})

    assert %{"status" => "cancelled"} = json_response(conn, 200)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "driver:frodo",
      event: "booking_request",
      payload: %{booking_id: ^booking_id, status: "cancelled"}
    }

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:luciano",
      event: "booking_request",
      payload: %{booking_id: ^booking_id, status: "cancelled"}
    }
  end
end
