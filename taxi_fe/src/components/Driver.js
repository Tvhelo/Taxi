import React, {useEffect, useState} from 'react';
import Button from '@mui/material/Button';

import socket from '../services/taxi_socket';
import { Card, CardContent, Typography } from '@mui/material';

function Driver(props) {
  let [message, setMessage] = useState();
  let [status, setStatus] = useState("idle");
  let [requests, setRequests] = useState({});

  useEffect(() => {
    let channel = socket.channel("driver:" + props.username, {token: "123"});
    channel.on("booking_request", data => {
      console.log("Received", data);
      let bookingId = data.booking_id || data.bookingId;

      setMessage(data.msg);
      setStatus(data.status || "requested");

      if (bookingId) {
        setRequests(previous => ({
          ...previous,
          [bookingId]: {
            ...(previous[bookingId] || {}),
            bookingId: bookingId,
            message: data.msg,
            status: data.status || "requested",
            visible: data.status === "requested"
          }
        }));
      }
    });
    channel.join()
      .receive("ok", () => console.log("Joined driver channel", props.username))
      .receive("error", error => console.error("Driver channel join failed", error))
      .receive("timeout", () => console.error("Driver channel join timed out"));

    return () => channel.leave();
  },[props.username]);

  let reply = (decision, bookingId) => {
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
      setRequests(previous => ({
        ...previous,
        [bookingId]: {
          ...(previous[bookingId] || {}),
          bookingId: bookingId,
          message: data.msg,
          status: data.status || decision,
          visible: false
        }
      }));
    });
  };

  let requestList = Object.values(requests);

  return (
    <div style={{textAlign: "center", borderStyle: "solid"}}>
        Driver: {props.username}
        <div>Estado: {status}</div>
        <div style={{backgroundColor: "lavender", minHeight: "100px"}}>
          <Typography>{message}</Typography>
          {
            requestList.map(request =>
              <Card key={request.bookingId} variant="outlined" style={{margin: "8px auto", width: "600px"}}>
                <CardContent>
                  <Typography>Booking: {request.bookingId}</Typography>
                  <Typography>{request.message}</Typography>
                  <Typography>Estado: {request.status}</Typography>
                </CardContent>
                {
                  request.visible ?
                  <>
                    <Button onClick={() => reply("accept", request.bookingId)} variant="outlined" color="primary">Accept</Button>
                    <Button onClick={() => reply("reject", request.bookingId)} variant="outlined" color="secondary">Reject</Button>
                  </> :
                  null
                }
              </Card>
            )
          }
        </div>
    </div>
  );
}

export default Driver;
