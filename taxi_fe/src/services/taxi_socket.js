import { Socket } from '../vendor/phoenix.mjs';

let socket = new Socket('ws://localhost:4000/socket', {params: {userToken: '123'}});

socket.onOpen(() => console.log('Phoenix socket connected'));
socket.onError(error => console.error('Phoenix socket error', error));
socket.onClose(event => console.warn('Phoenix socket closed', event));

socket.connect();

export default socket;
