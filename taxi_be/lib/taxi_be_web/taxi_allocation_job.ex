defmodule TaxiBeWeb.TaxiAllocationJob do
  use GenServer, restart: :temporary

  require Logger

  @allocation_timeout_ms 90_000
  @cleanup_ms 90_000
  @fare 80.0
  @eta_minutes 5

  def start_booking(request) do
    booking_id = UUID.uuid4()
    request = Map.put(request, "booking_id", booking_id)

    child_spec = %{
      id: {__MODULE__, booking_id},
      start: {__MODULE__, :start_link, [request]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(TaxiBe.BookingSupervisor, child_spec) do
      {:ok, _pid} -> {:ok, booking_id}
      {:error, {:already_started, _pid}} -> {:error, :already_started}
      {:error, reason} -> {:error, reason}
    end
  end

  def accept_booking(booking_id, username) do
    reply(booking_id, {:driver_reply, :accept, username})
  end

  def reject_booking(booking_id, username) do
    reply(booking_id, {:driver_reply, :reject, username})
  end

  def cancel_booking(booking_id, username) do
    reply(booking_id, {:customer_cancel, username})
  end

  def start_link(request) do
    GenServer.start_link(__MODULE__, request, name: via(request["booking_id"]))
  end

  @impl true
  def init(request) do
    Process.send(self(), :allocate_taxi, [])

    {:ok,
     %{
       booking_id: request["booking_id"],
       request: request,
       status: :created,
       fare: nil,
       candidate_taxis: [],
       candidate_drivers: MapSet.new(),
       pending_drivers: MapSet.new(),
       rejected_drivers: MapSet.new(),
       accepted_driver: nil,
       timer_ref: nil,
       cleanup_ref: nil
     }}
  end

  @impl true
  def handle_info(:allocate_taxi, state) do
    Logger.info("Booking #{state.booking_id}: allocation started")

    notify_customer(state, %{
      status: "searching",
      msg: "Solicitud recibida. Calculando tarifa y buscando conductores."
    })

    fare_task = Task.async(fn -> compute_ride_fare(state.request) end)
    taxis_task = Task.async(fn -> select_candidate_taxis(state.request) end)

    fare = Task.await(fare_task)
    taxis = Task.await(taxis_task)
    driver_names = taxis |> Enum.map(& &1.nickname) |> MapSet.new()

    state =
      state
      |> Map.put(:fare, fare)
      |> Map.put(:candidate_taxis, taxis)
      |> Map.put(:candidate_drivers, driver_names)
      |> Map.put(:pending_drivers, driver_names)
      |> notify_customer_ride_fare(fare)

    contact_candidate_taxis(state, taxis)
  end

  @impl true
  def handle_info(:driver_timeout, %{status: :awaiting_drivers} = state) do
    Logger.info(
      "Booking #{state.booking_id}: allocation timed out with #{MapSet.size(state.pending_drivers)} pending drivers"
    )

    state =
      state
      |> clear_timer()
      |> notify_pending_drivers(%{
        status: "expired",
        msg: "La solicitud expiro.",
        booking_id: state.booking_id,
        bookingId: state.booking_id
      })
      |> notify_no_driver("No se encontraron conductores disponibles.")
      |> Map.put(:status, :no_driver)
      |> Map.put(:pending_drivers, MapSet.new())
      |> schedule_cleanup()

    {:noreply, state}
  end

  def handle_info(:driver_timeout, state), do: {:noreply, state}

  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) when is_reference(ref) do
    {:noreply, state}
  end

  def handle_info(:shutdown_booking, state) do
    Logger.info("Booking #{state.booking_id}: process finished")
    {:stop, :normal, state}
  end

  @impl true
  def handle_call({:driver_reply, :accept, username}, _from, %{status: :awaiting_drivers} = state) do
    cond do
      not candidate_driver?(state, username) ->
        {:reply, {:error, :not_current_driver}, state}

      not pending_driver?(state, username) ->
        {:reply, {:ok, ignored_payload(state)}, state}

      true ->
        Logger.info("Booking #{state.booking_id}: accepted by #{username}")

        payload = accepted_payload(state, username)

        state =
          state
          |> clear_timer()
          |> Map.put(:status, :accepted)
          |> Map.put(:accepted_driver, username)
          |> Map.put(:pending_drivers, MapSet.delete(state.pending_drivers, username))
          |> notify_customer(payload)
          |> notify_other_pending_drivers(username, %{
            status: "cancelled",
            msg: "La solicitud fue asignada a otro conductor.",
            booking_id: state.booking_id,
            bookingId: state.booking_id
          })
          |> Map.put(:pending_drivers, MapSet.new())
          |> schedule_cleanup()

        {:reply, {:ok, payload}, state}
    end
  end

  def handle_call({:driver_reply, :reject, username}, _from, %{status: :awaiting_drivers} = state) do
    cond do
      not candidate_driver?(state, username) ->
        {:reply, {:error, :not_current_driver}, state}

      not pending_driver?(state, username) ->
        {:reply, {:ok, ignored_payload(state)}, state}

      true ->
        Logger.info("Booking #{state.booking_id}: rejected by #{username}")

        pending_drivers = MapSet.delete(state.pending_drivers, username)
        rejected_drivers = MapSet.put(state.rejected_drivers, username)

        state =
          state
          |> Map.put(:pending_drivers, pending_drivers)
          |> Map.put(:rejected_drivers, rejected_drivers)

        if MapSet.size(pending_drivers) == 0 do
          state =
            state
            |> clear_timer()
            |> Map.put(:status, :no_driver)
            |> notify_no_driver(
              "Los conductores rechazaron el viaje. No hay conductores disponibles."
            )
            |> schedule_cleanup()

          {:reply,
           {:ok,
            %{status: "rejected", msg: "Rechazo recibido. No quedan conductores pendientes."}},
           state}
        else
          {:reply,
           {:ok,
            %{
              status: "rejected",
              msg: "Rechazo recibido. Esperando respuesta de otros conductores."
            }}, state}
        end
    end
  end

  def handle_call({:driver_reply, _decision, _username}, _from, %{status: :accepted} = state) do
    {:reply, {:ok, ignored_payload(state)}, state}
  end

  def handle_call({:driver_reply, _decision, username}, _from, state) do
    if candidate_driver?(state, username) do
      {:reply, {:ok, ignored_payload(state)}, state}
    else
      {:reply, {:error, :not_current_driver}, state}
    end
  end

  def handle_call({:customer_cancel, username}, _from, state) do
    case state.request["username"] == username do
      true ->
        Logger.info("Booking #{state.booking_id}: cancelled by #{username}")

        state =
          state
          |> clear_timer()
          |> notify_pending_drivers(%{
            status: "cancelled",
            msg: "El cliente cancelo la solicitud.",
            booking_id: state.booking_id,
            bookingId: state.booking_id
          })
          |> Map.put(:status, :cancelled)
          |> Map.put(:pending_drivers, MapSet.new())
          |> notify_customer(%{status: "cancelled", msg: "Reservacion cancelada."})
          |> schedule_cleanup()

        {:reply, {:ok, %{status: "cancelled", msg: "Reservacion cancelada."}}, state}

      false ->
        {:reply, {:error, :not_booking_customer}, state}
    end
  end

  def compute_ride_fare(_request), do: @fare

  def notify_customer_ride_fare(state, fare) do
    notify_customer(state, %{
      status: "fare_estimated",
      fare: fare,
      msg: "Tarifa estimada: $#{format_money(fare)}. Buscando conductor."
    })
  end

  def select_candidate_taxis(%{"pickup_address" => pickup_address}) do
    if String.contains?(String.downcase(pickup_address), "sin conductores") do
      []
    else
      [
        %{nickname: "frodo", latitude: 19.0319783, longitude: -98.2349368},
        %{nickname: "samwise", latitude: 19.0061167, longitude: -98.2697737},
        %{nickname: "merry", latitude: 19.0092933, longitude: -98.2473716}
      ]
    end
  end

  defp reply(booking_id, message) do
    case Registry.lookup(TaxiBe.BookingRegistry, booking_id) do
      [{pid, _value}] -> GenServer.call(pid, message)
      [] -> {:error, :not_found}
    end
  end

  defp via(booking_id), do: {:via, Registry, {TaxiBe.BookingRegistry, booking_id}}

  defp contact_candidate_taxis(state, []) do
    Logger.info("Booking #{state.booking_id}: no candidate drivers found")

    state =
      state
      |> Map.put(:status, :no_driver)
      |> notify_no_driver("No se encontraron conductores disponibles.")
      |> schedule_cleanup()

    {:noreply, state}
  end

  defp contact_candidate_taxis(state, taxis) do
    driver_names = Enum.map(taxis, & &1.nickname)

    Logger.info(
      "Booking #{state.booking_id}: requesting #{length(driver_names)} drivers simultaneously: #{Enum.join(driver_names, ", ")}"
    )

    taxis
    |> Enum.map(fn taxi ->
      Task.async(fn ->
        broadcast_driver(taxi.nickname, driver_request_payload(state, taxi))
        taxi.nickname
      end)
    end)
    |> Enum.each(fn task ->
      Logger.info("Booking #{state.booking_id}: request sent to #{Task.await(task)}")
    end)

    timer_ref = Process.send_after(self(), :driver_timeout, allocation_timeout_ms())

    {:noreply,
     state
     |> Map.put(:status, :awaiting_drivers)
     |> Map.put(:timer_ref, timer_ref)}
  end

  defp accepted_payload(state, username) do
    %{
      status: "accepted",
      driver: username,
      eta_minutes: @eta_minutes,
      fare: state.fare,
      msg: "Tu conductor #{username} acepto. Llegara en #{@eta_minutes} min."
    }
  end

  defp ignored_payload(%{status: :accepted, accepted_driver: driver}) do
    %{
      status: "already_assigned",
      driver: driver,
      msg: "El viaje ya fue asignado a #{driver}."
    }
  end

  defp ignored_payload(%{status: :no_driver}) do
    %{status: "finished", msg: "La reservacion ya finalizo sin conductor."}
  end

  defp ignored_payload(%{status: :cancelled}) do
    %{status: "cancelled", msg: "La reservacion fue cancelada."}
  end

  defp ignored_payload(_state), do: %{status: "ignored", msg: "Respuesta ignorada."}

  defp driver_request_payload(state, _taxi) do
    %{
      status: "requested",
      booking_id: state.booking_id,
      bookingId: state.booking_id,
      pickup_address: state.request["pickup_address"],
      dropoff_address: state.request["dropoff_address"],
      customer_username: state.request["username"],
      fare: state.fare,
      msg:
        "Viaje de '#{state.request["pickup_address"]}' a '#{state.request["dropoff_address"]}'. Tarifa: $#{format_money(state.fare)}"
    }
  end

  defp candidate_driver?(state, username), do: MapSet.member?(state.candidate_drivers, username)

  defp pending_driver?(state, username), do: MapSet.member?(state.pending_drivers, username)

  defp notify_no_driver(state, msg) do
    notify_customer(state, %{status: "no_driver", msg: msg})
  end

  defp notify_customer(state, payload) do
    customer = state.request["username"]

    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> customer,
      "booking_request",
      Map.merge(%{booking_id: state.booking_id, bookingId: state.booking_id}, payload)
    )

    state
  end

  defp notify_pending_drivers(state, payload) do
    Enum.each(state.pending_drivers, &broadcast_driver(&1, payload))
    state
  end

  defp notify_other_pending_drivers(state, accepted_driver, payload) do
    state.pending_drivers
    |> MapSet.delete(accepted_driver)
    |> Enum.each(&broadcast_driver(&1, payload))

    state
  end

  defp broadcast_driver(username, payload) do
    TaxiBeWeb.Endpoint.broadcast("driver:" <> username, "booking_request", payload)
  end

  defp clear_timer(%{timer_ref: nil} = state), do: state

  defp clear_timer(state) do
    Process.cancel_timer(state.timer_ref)
    Map.put(state, :timer_ref, nil)
  end

  defp schedule_cleanup(%{cleanup_ref: nil} = state) do
    Map.put(state, :cleanup_ref, Process.send_after(self(), :shutdown_booking, cleanup_ms()))
  end

  defp schedule_cleanup(state), do: state

  defp allocation_timeout_ms do
    Application.get_env(:taxi_be, :allocation_timeout_ms, @allocation_timeout_ms)
  end

  defp cleanup_ms do
    Application.get_env(:taxi_be, :allocation_cleanup_ms, @cleanup_ms)
  end

  defp format_money(amount), do: :erlang.float_to_binary(amount, decimals: 2)
end
