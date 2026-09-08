#!/usr/bin/env node
import assert from 'node:assert/strict';
import net from 'node:net';
import { once } from 'node:events';

const connections = new Set();
const server = net.createServer(socket => {
  connections.add(socket);
  socket.once('close', () => connections.delete(socket));
  // pipe handles writable backpressure and EOF; TCP does not preserve writes.
  socket.pipe(socket);
});
server.listen(0, '127.0.0.1');
await once(server, 'listening');
const client = net.connect(server.address().port, '127.0.0.1');
const watchdog = setTimeout(
  () => client.destroy(new Error('echo timed out')),
  5000,
);
try {
  await once(client, 'connect');
  client.write('he');
  client.end('llo');
  const chunks = [];
  for await (const chunk of client) chunks.push(chunk);
  const reply = Buffer.concat(chunks).toString();
  assert.equal(reply, 'hello');
  console.log('echoed:', reply);
} finally {
  clearTimeout(watchdog);
  client.destroy();
  for (const socket of connections) socket.destroy();
  await new Promise(resolve => server.close(resolve));
}
