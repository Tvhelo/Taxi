defmodule TaxiBeWeb.BookingController do
  use TaxiBeWeb, :controller

  alias TaxiBeWeb.TaxiAllocationJob

  def create(conn, req) do
    with :ok <- validate_create(req),
         {:ok, booking_id} <- TaxiAllocationJob.start_booking(req) do
      conn
      |> put_resp_header("location", "/api/bookings/" <> booking_id)
      |> put_status(:created)
      |> json(%{
        booking_id: booking_id,
        msg: "Estamos procesando tu solicitud."
      })
    else
      {:error, :missing_fields} ->
        conn
        |> put_status(:bad_request)
        |> json(%{msg: "pickup_address, dropoff_address y username son obligatorios."})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{msg: "No se pudo crear la reservacion.", reason: inspect(reason)})
    end
  end

  def update(conn, %{"action" => "accept", "username" => username, "id" => id}) do
    respond_to_reply(conn, TaxiAllocationJob.accept_booking(id, username))
  end

  def update(conn, %{"action" => "reject", "username" => username, "id" => id}) do
    respond_to_reply(conn, TaxiAllocationJob.reject_booking(id, username))
  end

  def update(conn, %{"action" => "cancel", "username" => username, "id" => id}) do
    respond_to_reply(conn, TaxiAllocationJob.cancel_booking(id, username))
  end

  def update(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{msg: "Accion invalida. Usa accept, reject o cancel."})
  end

  def cancel(conn, %{"username" => username, "id" => id}) do
    respond_to_reply(conn, TaxiAllocationJob.cancel_booking(id, username))
  end

  defp validate_create(params) do
    required_fields = [
      params["pickup_address"],
      params["dropoff_address"],
      params["username"]
    ]

    if Enum.all?(required_fields, &present?/1) do
      :ok
    else
      {:error, :missing_fields}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp respond_to_reply(conn, {:ok, payload}), do: json(conn, payload)

  defp respond_to_reply(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{msg: "Reservacion no encontrada o ya finalizada."})
  end

  defp respond_to_reply(conn, {:error, :not_current_driver}) do
    conn
    |> put_status(:conflict)
    |> json(%{msg: "Este conductor no tiene asignada la reservacion."})
  end

  defp respond_to_reply(conn, {:error, :not_booking_customer}) do
    conn
    |> put_status(:forbidden)
    |> json(%{msg: "Solo el cliente de la reservacion puede cancelarla."})
  end
end
