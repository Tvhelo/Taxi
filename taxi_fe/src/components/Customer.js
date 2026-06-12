import React, {useEffect, useState} from 'react';
import Button from '@mui/material/Button'

import socket from '../services/taxi_socket';
import { TextField } from '@mui/material';

function Customer(props) {
  let [pickupAddress, setPickupAddress] = useState("Tecnologico de Monterrey, campus Puebla, Mexico");
  let [dropOffAddress, setDropOffAddress] = useState("Triangulo Las Animas, Puebla, Mexico");
  let [msg, setMsg] = useState("");
  let [bookingId, setBookingId] = useState("");
  let [status, setStatus] = useState("idle");
  let [cancellationFee, setCancellationFee] = useState(null);

  useEffect(() => {
    let channel = socket.channel("customer:" + props.username, {token: "123"});
    channel.on("greetings", data => console.log(data));
    channel.on("booking_request", data => {
      console.log("Received", data);
      if (data.booking_id || data.bookingId) {
        setBookingId(data.booking_id || data.bookingId);
      }
      if (data.status) {
        setStatus(data.status);
      }
      if (data.cancellation_fee !== undefined) {
        setCancellationFee(data.cancellation_fee);
      }
      setMsg(data.msg);
    });
    channel.join()
      .receive("ok", () => console.log("Joined customer channel", props.username))
      .receive("error", error => console.error("Customer channel join failed", error))
      .receive("timeout", () => console.error("Customer channel join timed out"));

    return () => channel.leave();
  },[props.username]);

  let submit = () => {
    fetch(`http://localhost:4000/api/bookings`, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({pickup_address: pickupAddress, dropoff_address: dropOffAddress, username: props.username})
    }).then(resp => resp.json()).then(data => {
      if (data.booking_id) {
        setBookingId(data.booking_id);
      }
      setStatus(data.booking_id ? "created" : "error");
      setCancellationFee(null);
      setMsg(data.msg);
    });
  };

  let cancel = () => {
    if (!bookingId) {
      setMsg("No hay reservacion activa para cancelar.");
      return;
    }

    fetch(`http://localhost:4000/api/bookings/${bookingId}`, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({action: "cancel", username: props.username})
    }).then(resp => resp.json()).then(data => {
      setBookingId("");
      setStatus(data.status || "cancelled");
      if (data.cancellation_fee !== undefined) {
        setCancellationFee(data.cancellation_fee);
      }
      setMsg(data.msg);
    });
  };

  return (
    <div style={{textAlign: "center", borderStyle: "solid"}}>
      Customer: {props.username}
      <div>
          <TextField id="outlined-basic" label="Pickup address"
            fullWidth
            onChange={ev => setPickupAddress(ev.target.value)}
            value={pickupAddress}/>
          <TextField id="outlined-basic" label="Drop off address"
            fullWidth
            onChange={ev => setDropOffAddress(ev.target.value)}
            value={dropOffAddress}/>
        <Button onClick={submit} variant="outlined" color="primary">Submit</Button>
        <Button onClick={cancel} variant="outlined" color="secondary">Cancel</Button>
      </div>
      <div style={{backgroundColor: "lightcyan", minHeight: "50px"}}>
        {msg}
      </div>
      <div>
        Estado: {status}
      </div>
      <div>
        {cancellationFee !== null ? `Cargo de cancelacion: $${Number(cancellationFee).toFixed(2)}` : null}
      </div>
      <div>
        {bookingId ? `Booking: ${bookingId}` : null}
      </div>
    </div>
  );
}

export default Customer;
