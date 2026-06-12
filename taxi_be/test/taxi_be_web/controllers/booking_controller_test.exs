defmodule TaxiBeWeb.BookingControllerTest do
  use TaxiBeWeb.ConnCase

  alias TaxiBeWeb.TaxiAllocationJob

  @drivers ["frodo", "samwise", "merry"]

  @booking_params %{
    "pickup_address" => "Tecnologico de Monterrey, campus Puebla, Mexico",
    "dropoff_address" => "Triangulo Las Animas, Puebla, Mexico",
    "username" => "luciano"
  }

  test "creates a booking, estimates fare, contacts three drivers and accepts the first winner",
       %{conn: conn} do
    subscribe_customer_and_drivers("luciano")

    conn = post(conn, ~p"/api/bookings", @booking_params)
    response = json_response(conn, 201)
    booking_id = response["booking_id"]

    assert response["msg"] == "Estamos procesando tu solicitud."
    assert_initial_customer_messages(booking_id, "luciano")
    assert_driver_requests(booking_id)

    conn =
      build_conn()
      |> post(~p"/api/bookings/#{booking_id}", %{action: "accept", username: "frodo"})

    assert %{
             "driver" => "frodo",
             "eta_minutes" => 5,
             "fare" => 80.0,
             "status" => "accepted"
           } = json_response(conn, 200)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:luciano",
      event: "booking_request",
      payload: %{booking_id: ^booking_id, status: "accepted", eta_minutes: 5}
    }

    assert_cancelled_for_other_drivers(booking_id, "frodo")
  end

  test "waits for all contacted drivers before notifying no driver", %{conn: conn} do
    subscribe_customer_and_drivers("luciano")

    conn = post(conn, ~p"/api/bookings", @booking_params)
    booking_id = json_response(conn, 201)["booking_id"]

    assert_initial_customer_messages(booking_id, "luciano")
    assert_driver_requests(booking_id)

    conn =
      build_conn()
      |> post(~p"/api/bookings/#{booking_id}", %{action: "reject", username: "frodo"})

    assert %{"status" => "rejected", "msg" => msg} = json_response(conn, 200)
    assert msg =~ "Esperando respuesta"
    refute_no_driver_for(booking_id)

    conn =
      build_conn()
      |> post(~p"/api/bookings/#{booking_id}", %{action: "reject", username: "samwise"})

    assert %{"status" => "rejected", "msg" => msg} = json_response(conn, 200)
    assert msg =~ "Esperando respuesta"
    refute_no_driver_for(booking_id)

    conn =
      build_conn()
      |> post(~p"/api/bookings/#{booking_id}", %{action: "reject", username: "merry"})

    assert %{"status" => "rejected", "msg" => msg} = json_response(conn, 200)
    assert msg =~ "No quedan conductores"

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:luciano",
      event: "booking_request",
      payload: %{booking_id: ^booking_id, status: "no_driver"}
    }
  end

  test "ignores late driver replies after a booking has already been assigned", %{conn: conn} do
    Phoenix.PubSub.subscribe(TaxiBe.PubSub, "customer:luciano")

    conn = post(conn, ~p"/api/bookings", @booking_params)
    booking_id = json_response(conn, 201)["booking_id"]
    assert_initial_customer_messages(booking_id, "luciano")

    conn =
      build_conn()
      |> post(~p"/api/bookings/#{booking_id}", %{action: "accept", username: "samwise"})

    assert %{"status" => "accepted", "driver" => "samwise"} = json_response(conn, 200)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:luciano",
      event: "booking_request",
      payload: %{booking_id: ^booking_id, status: "accepted", driver: "samwise"}
    }

    conn =
      build_conn()
      |> post(~p"/api/bookings/#{booking_id}", %{action: "accept", username: "frodo"})

    assert %{"status" => "already_assigned", "driver" => "samwise"} = json_response(conn, 200)
    refute_no_duplicate_acceptance_for(booking_id)
  end

  test "serializes simultaneous acceptances so only one driver wins", %{conn: conn} do
    Phoenix.PubSub.subscribe(TaxiBe.PubSub, "driver:frodo")

    conn = post(conn, ~p"/api/bookings", @booking_params)
    booking_id = json_response(conn, 201)["booking_id"]

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "driver:frodo",
      event: "booking_request",
      payload: %{booking_id: ^booking_id, status: "requested"}
    }

    responses =
      ["frodo", "samwise"]
      |> Enum.map(fn driver ->
        Task.async(fn -> TaxiAllocationJob.accept_booking(booking_id, driver) end)
      end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(responses, &accepted_response?/1) == 1
    assert Enum.count(responses, &already_assigned_response?/1) == 1
  end

  test "notifies the customer when the allocation times out", %{conn: conn} do
    subscribe_customer_and_drivers("luciano")

    conn = post(conn, ~p"/api/bookings", @booking_params)
    booking_id = json_response(conn, 201)["booking_id"]

    assert_initial_customer_messages(booking_id, "luciano")
    assert_driver_requests(booking_id)

    assert_receive %Phoenix.Socket.Broadcast{
                     topic: "customer:luciano",
                     event: "booking_request",
                     payload: %{booking_id: ^booking_id, status: "no_driver"}
                   },
                   300

    Enum.each(@drivers, fn driver ->
      assert_receive %Phoenix.Socket.Broadcast{
        topic: "driver:" <> ^driver,
        event: "booking_request",
        payload: %{booking_id: ^booking_id, status: "expired"}
      }
    end)
  end

  test "notifies the customer when no candidate drivers are available", %{conn: conn} do
    Phoenix.PubSub.subscribe(TaxiBe.PubSub, "customer:luciano")

    conn =
      post(conn, ~p"/api/bookings", %{
        @booking_params
        | "pickup_address" => "sin conductores"
      })

    booking_id = json_response(conn, 201)["booking_id"]

    assert_initial_customer_messages(booking_id, "luciano")

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:luciano",
      event: "booking_request",
      payload: %{booking_id: ^booking_id, status: "no_driver"}
    }
  end

  test "keeps simultaneous bookings isolated by booking id", %{conn: _conn} do
    Phoenix.PubSub.subscribe(TaxiBe.PubSub, "driver:frodo")
    Phoenix.PubSub.subscribe(TaxiBe.PubSub, "driver:merry")

    booking_params_1 = Map.put(@booking_params, "username", "luciano")
    booking_params_2 = Map.put(@booking_params, "username", "bilbo")

    task_1 = Task.async(fn -> post(build_conn(), ~p"/api/bookings", booking_params_1) end)
    task_2 = Task.async(fn -> post(build_conn(), ~p"/api/bookings", booking_params_2) end)

    booking_id_1 = task_1 |> Task.await() |> json_response(201) |> Map.fetch!("booking_id")
    booking_id_2 = task_2 |> Task.await() |> json_response(201) |> Map.fetch!("booking_id")

    assert booking_id_1 != booking_id_2

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "driver:frodo",
      event: "booking_request",
      payload: %{booking_id: ^booking_id_1, status: "requested"}
    }

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "driver:frodo",
      event: "booking_request",
      payload: %{booking_id: ^booking_id_2, status: "requested"}
    }

    assert {:ok, %{status: "accepted", driver: "frodo"}} =
             TaxiAllocationJob.accept_booking(booking_id_1, "frodo")

    assert {:ok, %{status: "accepted", driver: "merry"}} =
             TaxiAllocationJob.accept_booking(booking_id_2, "merry")
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
      |> post(~p"/api/bookings/#{booking_id}", %{action: "accept", username: "pippin"})

    assert %{"msg" => "Este conductor no tiene asignada la reservacion."} =
             json_response(conn, 409)
  end

  test "lets the booking customer cancel an active request", %{conn: conn} do
    subscribe_customer_and_drivers("luciano")

    conn = post(conn, ~p"/api/bookings", @booking_params)
    booking_id = json_response(conn, 201)["booking_id"]

    assert_initial_customer_messages(booking_id, "luciano")
    assert_driver_requests(booking_id)

    conn =
      build_conn()
      |> post(~p"/api/bookings/#{booking_id}", %{action: "cancel", username: "luciano"})

    assert %{"status" => "cancelled"} = json_response(conn, 200)

    Enum.each(@drivers, fn driver ->
      assert_receive %Phoenix.Socket.Broadcast{
        topic: "driver:" <> ^driver,
        event: "booking_request",
        payload: %{booking_id: ^booking_id, status: "cancelled"}
      }
    end)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:luciano",
      event: "booking_request",
      payload: %{booking_id: ^booking_id, status: "cancelled"}
    }
  end

  defp subscribe_customer_and_drivers(customer) do
    Phoenix.PubSub.subscribe(TaxiBe.PubSub, "customer:" <> customer)
    Enum.each(@drivers, &Phoenix.PubSub.subscribe(TaxiBe.PubSub, "driver:" <> &1))
  end

  defp assert_initial_customer_messages(booking_id, customer) do
    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:" <> ^customer,
      event: "booking_request",
      payload: %{booking_id: ^booking_id, status: "searching"}
    }

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "customer:" <> ^customer,
      event: "booking_request",
      payload: %{booking_id: ^booking_id, status: "fare_estimated", fare: 80.0}
    }
  end

  defp assert_driver_requests(booking_id) do
    Enum.each(@drivers, fn driver ->
      assert_receive %Phoenix.Socket.Broadcast{
        topic: "driver:" <> ^driver,
        event: "booking_request",
        payload: %{booking_id: ^booking_id, status: "requested", fare: 80.0}
      }
    end)
  end

  defp assert_cancelled_for_other_drivers(booking_id, accepted_driver) do
    @drivers
    |> Enum.reject(&(&1 == accepted_driver))
    |> Enum.each(fn driver ->
      assert_receive %Phoenix.Socket.Broadcast{
        topic: "driver:" <> ^driver,
        event: "booking_request",
        payload: %{booking_id: ^booking_id, status: "cancelled"}
      }
    end)
  end

  defp refute_no_driver_for(booking_id) do
    refute_receive %Phoenix.Socket.Broadcast{
                     topic: "customer:luciano",
                     event: "booking_request",
                     payload: %{booking_id: ^booking_id, status: "no_driver"}
                   },
                   30
  end

  defp refute_no_duplicate_acceptance_for(booking_id) do
    refute_receive %Phoenix.Socket.Broadcast{
                     topic: "customer:luciano",
                     event: "booking_request",
                     payload: %{booking_id: ^booking_id, status: "accepted"}
                   },
                   30
  end

  defp accepted_response?({:ok, %{status: "accepted"}}), do: true
  defp accepted_response?(_response), do: false

  defp already_assigned_response?({:ok, %{status: "already_assigned"}}), do: true
  defp already_assigned_response?(_response), do: false
end
