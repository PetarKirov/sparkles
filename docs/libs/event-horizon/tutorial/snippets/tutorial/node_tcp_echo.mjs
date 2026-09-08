#!/usr/bin/env node
import net from 'node:net';
import { once } from 'node:events';

const peers = new Set();
let serverError;
const server = net.createServer(socket => {
  peers.add(socket);
  socket.on('error', error => {
    serverError = error;
    socket.destroy();
  });
  socket.once('close', () => peers.delete(socket));
  socket.pipe(socket); // Handles backpressure; EOF ends the response.
});
server.listen(0, '127.0.0.1');
await once(server, 'listening');
const client = net.connect(server.address().port, '127.0.0.1');
client.setTimeout(5000, () => client.destroy(new Error('echo timed out')));
try {
  await once(client, 'connect');
  client.end('hello');
  const chunks = [];
  for await (const chunk of client) chunks.push(chunk);
  if (serverError) throw serverError;
  console.log('echoed:', Buffer.concat(chunks).toString());
} finally {
  client.destroy();
  for (const peer of peers) peer.destroy();
  await new Promise(resolve => server.close(resolve));
}
