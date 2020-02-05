import deques, math, tables, strformat
import sugar, options, times
import bson, wire, auth
import scram/client

{.warning[UnusedImport]: off.}

type
  Connection* = object
    socket*: AsyncSocket
    id*: int

  Pool* = ref object
    connections: TableRef[int, Connection]
    available*: Deque[int]

proc connections*(p: Pool): lent TableRef[int, Connection] =
  p.connections

proc initConnection*(id = 0): Connection =
  result.socket = newAsyncSocket()
  result.id = id

proc contains*(p: Pool, i: int): bool =
  i in p.connections

proc `[]`*(p: Pool, i: int): Connection =
  p.connections[i]

proc `[]=`*(p: Pool, i: int, c: Connection) =
  p.connections[i] = c

proc initPool*(size = 16): Pool =
  new result
  let realsize = nextPowerOfTwo size
  result.connections = newTable[int, Connection](realsize)
  result.available = initDeque[int](realsize)
  for i in 1 .. realsize:
    result[i] = i.initConnection
    result.available.addFirst i

proc getConn*(p: Pool): Future[(int, Connection)] {.async.} =
  while true:
    if p.available.len > 0:
      let id = p.available.popLast
      let conn = p.connections[id]
      #when not defined(release):
        #dump id
      result = (id, conn)
      return
    else:
      try: poll(100)
      except ValueError: discard

proc connect*(p: Pool, address: string, port: int) {.async.} =
  for i, c in p.connections:
    await c.socket.connect(address, Port port)
    when not defined(release):
      echo "connection: ", i, " is connected"

proc close*(p: Pool) =
  for _, c in p.connections:
      if not c.socket.isClosed:
        close c.socket
        when not defined(release):
          echo "connection: ", c.id, " is closed"

proc endConn*(p: Pool, i: Positive) =
  p.available.addFirst i.int

proc authenticate*(p: Pool, user, pass: string, T: typedesc = Sha1Digest,
  dbname = "admin.$cmd"): Future[bool] {.async.} =
  result = true
  for i, c in p.connections:
    echo &"conn {i} to auth."
    if not await c.socket.authenticate(user, pass, T, dbname):
      result = false
      return
    echo &"connection {i} authenticated."

when isMainModule:

  proc query1(s: AsyncSocket, db: string, id: int32) {.async.} =
    look(await queryAck(s, id, db, "role", limit = 1))

  #[
  proc handshake(s: AsyncSocket, db: string, id: int32) {.async.} =
    let q = bson({
      isMaster: 1,
      client: {
        application: { name: "test connection pool: " & $id },
        driver: {
          name: "anonimongo - nim mongo driver",
          version: "0.0.4",
        },
        os: {
          "type": "Windows",
          architecture: "amd64"
        }
      }
    })
    echo "Handshake id: ", id
    dump q
    var stream = newStringStream()
    discard stream.prepareQuery(id, 0, opQuery.int32, 0, db,
      0, 1, q)
    await s.send stream.readAll
    look(await s.getReply)
    ]#
  proc toHandshake(pool: Pool, i: int) {.async.} =
    echo "spawning: ", i
    let (cid, conn) = await pool.getConn
    defer: pool.endConn cid
    await conn.socket.query1("temptest", conn.id.int32)
    echo "end conn: ", conn.id

  proc dummy(pool: Pool, i: int) {.async.} =
    echo "spawning: ", i
    let (cid, conn) = await pool.getConn
    defer: pool.endConn cid
    await sleepAsync(200)
    echo "end conn: ", conn.id

  proc main {.async.} =
    let poolSize = 16
    let loopsize = poolsize * 3
    var pool = initPool(poolSize)
    #[
    waitFor pool.connect("localhost", 27017)
    if not waitFor pool.authenticate("rdruffy", "rdruffy"):
      echo "cannot authenticate"
      return
      ]#

    let starttime = cpuTime()
    var ops = newseq[Future[void]](loopsize)
    for count in 0 ..< loopSize:
      #ops[count] = pool.toHandshake(count)
      ops[count] = pool.dummy(count)
    try:
      await all(ops)
    except:
      echo getCurrentExceptionMsg()
    when not defined(release):
      dump pool.available
    echo "ended loop at: ", cpuTime() - starttime

    close pool

  let start = cpuTime()
  waitFor main()
  echo "whole operation: ", cpuTime() - start
