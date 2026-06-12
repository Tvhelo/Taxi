import React, {useEffect, useState} from 'react';
import Button from '@mui/material/Button';

import socket from '../services/taxi_socket';
import { Card, CardContent, Typography } from '@mui/material';

function Driver(props) {
  let [message, setMessage] = useState();
  let [bookingId, setBookingId] = useState();
  let [visible, setVisible] = useState(false);
  let [status, setStatus] = useState("idle");

  useEffect(() => {
    let channel = socket.channel("driver:" + props.username, {token: "123"});
    channel.on("booking_request", data => {
      console.log("Received", data);
      setMessage(data.msg);
      setBookingId(data.booking_id || data.bookingId);
      setStatus(data.status || "requested");
      setVisible(data.status === "requested");
    });
    channel.join()
      .receive("ok", () => console.log("Joined driver channel", props.username))
      .receive("error", error => console.error("Driver channel join failed", error))
      .receive("timeout", () => console.error("Driver channel join timed out"));

    return () => channel.leave();
  },[props.username]);

  let reply = (decision) => {
    if (!bookingId) {
      return;
    }

    fetch(`http://localhost:4000/api/bookings/${bookingId}`, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({action: decision, username: props.username})
    }).then(resp => resp.json()).then(data => {
      setMessage(data.msg);
      setStatus(data.status || decision);
      setBookingId();
      setVisible(false);
    });
  };

  return (
    <div style={{textAlign: "center", borderStyle: "solid"}}>
        Driver: {props.username}
        <div>Estado: {status}</div>
        <div style={{backgroundColor: "lavender", height: "100px"}}>
          <Typography>{message}</Typography>
          {
            visible ?
            <Card variant="outlined" style={{margin: "auto", width: "600px"}}>
              <CardContent>
                <Typography>Booking: {bookingId}</Typography>
              </CardContent>
              <Button onClick={() => reply("accept")} variant="outlined" color="primary">Accept</Button>
              <Button onClick={() => reply("reject")} variant="outlined" color="secondary">Reject</Button>
            </Card> :
            null
          }
        </div>
    </div>
  );
}

export default Driver;
