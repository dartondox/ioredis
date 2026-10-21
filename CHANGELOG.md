## 2.0.0-alpha.1

This is a prerelease. The API can still change before 2.0.0.

Breaking changes:

- Integer replies are now `int`, not `String`. For example `INCR` gives `1`, not `'1'`.
- An error reply from Redis now throws `RedisError`. Before, the error text was returned as a value, or `null`.
- A lost connection now fails the waiting commands with `SocketException`. Before, they could wait forever.
- `set()` now returns the reply (`'OK'`, `null` for NX/XX, or the old value for GET). Before, it threw when the reply was not `OK`.
- `set()` with an option and no value now sends the option (for `'NX'`, `'XX'`, `'GET'`, `'KEEPTTL'`). Before, the option was dropped.
- `multi().exec()` throws `RedisError` (EXECABORT) when Redis rejects a queued command. Errors of single commands are `RedisError` items in the result.
- `publish()` now returns the number of clients that got the message.
- `RedisConnection.isBusy` is now a getter.
- `Redis()` without options no longer shares one global options object.

Fixes:

- New streaming RESP2 parser. It works when a reply is split over many TCP chunks, when one chunk has many replies, with nested arrays, with bulk strings that contain `\r\n`, and with UTF-8 characters split across chunks. Fixes #8 (GEOSEARCH) and #10 (large SMEMBERS).
- `multi()` now runs MULTI, the commands and EXEC on one connection, in one write.
- The connection keeps working after an error reply.
- A `RedisOptions` without `retryStrategy` no longer crashes on reconnect.

New:

- `call()` to send any command.
- `pipeline()` to send many commands in one write.
- `multi()` and `pipeline()` accept any command with `.call()`.
- Typed methods for keys, strings, hashes, lists, sets, sorted sets, server, scripting and pub/sub (`psubscribe`, `unsubscribe`, `punsubscribe`).
- `RedisError` is exported.

## 1.0.3

- Add onBadCertificate field and improve code consistency

## 1.0.2

- Add support for pool connections
- Bug fixed on array result
- Add support for multi commands (pipelining)

## 1.0.1

- Bug fixed on parallel request

## 1.0.0

- Release stable version.

## 1.0.0-beta.0

- Initial version.
