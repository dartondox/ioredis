## Unreleased

Faster. With 64 commands in flight, a GET costs about 10 times less CPU
(13.8 µs down to 1.2 µs per command on an Apple M-series Mac), and
throughput goes from about 76k to 345k ops/s.

Changes:

- Auto-pipelining. Commands sent in the same event-loop turn are written
  together in one socket write. Replies still go to the right caller.
- Commands share the main connection. Before, every command that came while
  the connection was waiting went to another pool connection, so each write
  held only one command. Now the pool is only used while a blocking command
  (BLPOP, BRPOP, BLMOVE, BLMPOP, BZPOPMIN, BZPOPMAX, BZMPOP, BRPOPLPUSH,
  XREAD/XREADGROUP with BLOCK, WAIT, WAITAOF) waits on a connection.
- New `RedisConnection.isBlocked` getter.
- The pool no longer creates and cancels a `Timer` for every command. One
  timer closes idle connections. A connection that still waits for a reply
  is not closed.
- The encoder writes straight into one reusable byte buffer.
- The reply parser reads the socket chunks in place. It no longer copies
  all unread bytes for every chunk, and it reads numbers from the bytes
  without making a `String`. Large replies split over many chunks are now
  read in linear time.
- A null value is now encoded as `$-1\r\n` (the `\r\n` was missing).
- Needs Dart 3.11 or newer (for the latest `test` and `lints`).

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
