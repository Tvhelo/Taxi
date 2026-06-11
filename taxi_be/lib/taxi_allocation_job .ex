defmodule TaxiBeWeb.TaxiAllocationJob do
  use GenServer

  def start_link(request, name) do
    GenServer.start_link(__MODULE__, request, name: name)
  end

  def init(request) do
    cont = 0
    Process.send(self(), :part1, [:nosuspend])
    {:ok, %{request: request, timer: nil}}
  end

  def handle_info(:part1,  %{request: request} = state) do
    Process.sleep(1000)

    task = Task.async( fn -> candidate_taxis() end)
    # Computation of fare
    TaxiBeWeb.Endpoint.broadcast("customer:luciano", "booking_request", %{msg: "Your ride is worth 80 pesitos"})

    taxis = Task.await(task)

    {taxi, others, timer} = part2(state |> Map.put(:taxis, taxis |> Enum.shuffle))
    {:noreply, state |> Map.put(:contacted_taxi, taxi) |> Map.put(:others, others) |> Map.put(:timer, timer)}
  end

  def handle_info(:timeout, state) do

    IO.puts("Boom !!!")
    {:noreply, state}
  end

  def handle_info(:part2, state) do
    IO.puts("Part 2")
    {:noreply, state}
  end

  def part2(state) do
    cont = Map.get(state, :cont, 0) + 1
    state = state |> Map.put(:cont, cont)

    if cont > 3 do
      IO.puts("No more taxis available")
      TaxiBeWeb.Endpoint.broadcast("customer:luciano", "booking_request", %{msg: "Sorry, no more taxis available"})
      return {nil, nil, nil}
    end

    %{taxis: taxis, request: request} = state

    [taxi | others] = taxis

    # Forward request to taxi driver
    %{
      "pickup_address" => pickup_address,
      "dropoff_address" => dropoff_address,
      "booking_id" => booking_id
    } = request
    TaxiBeWeb.Endpoint.broadcast(
      "driver:" <> taxi.nickname,
      "booking_request",
       %{
         msg: "Viaje de '#{pickup_address}' a '#{dropoff_address}'",
         bookingId: booking_id
        })

    if Enum.random(0..1)== 0 do
      state = state |> Map.put(:accepted, taxi)
      TaxiBeWeb.Endpoint.broadcast("customer:luciano", "booking_request", %{msg: "Tu taxi es #{taxi.nickname}"})
      {taxi, others, nil}
    end

    timer = Process.send_after(self(), :timeout, 10000)

    if state.accepted == nil do
      Process.send_after(self(), :part2, 11000)
    end
    {taxi, others, timer}
  end


  def handle_cast(request, state) do
    IO.inspect(request)
    IO.inspect(state)

    %{timer: timer} = state

    if timer != nil do
      Process.cancel_timer(timer)
    end

    TaxiBeWeb.Endpoint.broadcast("customer:luciano", "booking_request", %{msg: "Tu taxi llegará en  5 min"})
    {:noreply, state}
  end

  def compute_ride_fare(request) do
    %{
      "pickup_address" => pickup_address,
      "dropoff_address" => dropoff_address
    } = request

    # coord1 = TaxiBeWeb.Geolocator.geocode(pickup_address)
    # coord2 = TaxiBeWeb.Geolocator.geocode(dropoff_address)
    # {distance, _duration} = TaxiBeWeb.Geolocator.distance_and_duration(coord1, coord2)
    {request, 80.0} # Float.ceil(distance/300)}
  end

  def notify_customer_ride_fare({request, fare}) do
    %{"username" => customer} = request
  TaxiBeWeb.Endpoint.broadcast("customer:" <> customer, "booking_request", %{msg: "Ride fare: #{fare}"})
  end

  def select_candidate_taxis(%{"pickup_address" => _pickup_address}) do
    [
      %{nickname: "angelopolis", latitude: 19.0319783, longitude: -98.2349368},
      %{nickname: "arcangeles", latitude: 19.0061167, longitude: -98.2697737},
      %{nickname: "destino", latitude: 19.0092933, longitude: -98.2473716}
    ]
  end

  def candidate_taxis() do
    [
      %{nickname: "frodo", latitude: 19.0319783, longitude: -98.2349368}, # Angelopolis
      %{nickname: "samwise", latitude: 19.0061167, longitude: -98.2697737}, # Arcangeles
      %{nickname: "pipin", latitude: 19.0092933, longitude: -98.2473716} # Paseo Destino
    ]
  end
end
