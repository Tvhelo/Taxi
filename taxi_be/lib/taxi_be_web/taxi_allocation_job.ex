defmodule TaxiBeWeb.TaxiAllocationJob do
  use GenServer, restart: :temporary

  require Logger

  @allocation_timeout_ms 30_000
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
       contacted_taxi: nil,
       remaining_taxis: [],
       timer_ref: nil
     }}
  end

  @impl true
  def handle_info(:allocate_taxi, state) do
    Logger.info("Booking #{state.booking_id}: allocation started")

    notify_customer(state, %{
      status: "searching",
      msg: "Solicitud recibida. Tarifa estimada: $#{format_money(@fare)}. Buscando conductor."
    })

    state
    |> Map.put(:remaining_taxis, select_candidate_taxis(state.request))
    |> contact_next_taxi()
  end

  @impl true
  def handle_info(:driver_timeout, %{status: :awaiting_driver} = state) do
    Logger.info("Booking #{state.booking_id}: driver #{state.contacted_taxi.nickname} timed out")

    state =
      state
      |> clear_timer()
      |> notify_no_driver("No se encontró conductor disponible.")

    {:stop, :normal, state}
  end

  def handle_info(:driver_timeout, state), do: {:noreply, state}

  @impl true
  def handle_call({:driver_reply, :accept, username}, _from, state) do
    case current_driver_reply?(state, username) do
      true ->
        Logger.info("Booking #{state.booking_id}: accepted by #{username}")

        payload = %{
          status: "accepted",
          driver: username,
          eta_minutes: @eta_minutes,
          msg: "Tu conductor #{username} acepto. Llegara en #{@eta_minutes} min."
        }

        state =
          state
          |> clear_timer()
          |> Map.put(:status, :accepted)
          |> notify_customer(payload)

        {:stop, :normal, {:ok, payload}, state}

      false ->
        {:reply, {:error, :not_current_driver}, state}
    end
  end

  def handle_call({:driver_reply, :reject, username}, _from, state) do
    case current_driver_reply?(state, username) do
      true ->
        Logger.info("Booking #{state.booking_id}: rejected by #{username}")

        state =
          state
          |> clear_timer()
          |> Map.put(:status, :rejected)
          |> notify_no_driver(
            "El conductor rechazo el viaje. No se encontro conductor disponible."
          )

        {:stop, :normal, {:ok, %{status: "rejected", msg: "Rechazo recibido."}}, state}

      false ->
        {:reply, {:error, :not_current_driver}, state}
    end
  end

  def handle_call({:customer_cancel, username}, _from, state) do
    case state.request["username"] == username do
      true ->
        Logger.info("Booking #{state.booking_id}: cancelled by #{username}")

        notify_driver(state, %{
          status: "cancelled",
          msg: "El cliente cancelo la solicitud.",
          booking_id: state.booking_id,
          bookingId: state.booking_id
        })

        state =
          state
          |> clear_timer()
          |> Map.put(:status, :cancelled)
          |> notify_customer(%{status: "cancelled", msg: "Reservacion cancelada."})

        {:stop, :normal, {:ok, %{status: "cancelled", msg: "Reservacion cancelada."}}, state}

      false ->
        {:reply, {:error, :not_booking_customer}, state}
    end
  end

  defp reply(booking_id, message) do
    case Registry.lookup(TaxiBe.BookingRegistry, booking_id) do
      [{pid, _value}] -> GenServer.call(pid, message)
      [] -> {:error, :not_found}
    end
  end

  defp via(booking_id), do: {:via, Registry, {TaxiBe.BookingRegistry, booking_id}}

  defp contact_next_taxi(%{remaining_taxis: []} = state) do
    state = notify_no_driver(state, "No se encontraron conductores disponibles.")
    {:stop, :normal, state}
  end

  defp contact_next_taxi(%{remaining_taxis: [taxi | others]} = state) do
    Logger.info("Booking #{state.booking_id}: requesting driver #{taxi.nickname}")

    state =
      state
      |> Map.put(:status, :awaiting_driver)
      |> Map.put(:contacted_taxi, taxi)
      |> Map.put(:remaining_taxis, others)

    notify_driver(state, %{
      status: "requested",
      booking_id: state.booking_id,
      bookingId: state.booking_id,
      pickup_address: state.request["pickup_address"],
      dropoff_address: state.request["dropoff_address"],
      customer_username: state.request["username"],
      fare: @fare,
      msg: "Viaje de '#{state.request["pickup_address"]}' a '#{state.request["dropoff_address"]}'"
    })

    timer_ref = Process.send_after(self(), :driver_timeout, @allocation_timeout_ms)
    {:noreply, Map.put(state, :timer_ref, timer_ref)}
  end

  defp current_driver_reply?(
         %{status: :awaiting_driver, contacted_taxi: %{nickname: username}},
         username
       ),
       do: true

  defp current_driver_reply?(_state, _username), do: false

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

  defp notify_driver(%{contacted_taxi: nil} = state, _payload), do: state

  defp notify_driver(state, payload) do
    TaxiBeWeb.Endpoint.broadcast(
      "driver:" <> state.contacted_taxi.nickname,
      "booking_request",
      payload
    )

    state
  end

  defp clear_timer(%{timer_ref: nil} = state), do: state

  defp clear_timer(state) do
    Process.cancel_timer(state.timer_ref)
    Map.put(state, :timer_ref, nil)
  end

  defp format_money(amount), do: :erlang.float_to_binary(amount, decimals: 2)

  def select_candidate_taxis(%{"pickup_address" => _pickup_address}) do
    [
      %{nickname: "frodo", latitude: 19.0319783, longitude: -98.2349368},
      %{nickname: "samwise", latitude: 19.0061167, longitude: -98.2697737},
      %{nickname: "merry", latitude: 19.0092933, longitude: -98.2473716}
    ]
  end
end
