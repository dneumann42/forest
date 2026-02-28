import std/[macros, strutils, macrocache, oids, hashes, tables, sets]

const entityTypes = CacheSeq"ForestEntityTypes"

macro entity*(typeDef: untyped): untyped =
  result = typeDef
  var typeName: NimNode
  if typeDef.kind == nnkTypeDef:
    var nameNode = typeDef[0]
    if nameNode.kind == nnkPragmaExpr:
      nameNode = nameNode[0]
    if nameNode.kind == nnkPostfix:
      typeName = nameNode[1]
    else:
      typeName = nameNode
    entityTypes.add(typeName)
  else:
    error("entity pragma can only be applied to type definitions", typeDef)

type
  EntityId* = distinct Oid

  EntityBuffer*[T] = ref object
    entityMap*: Table[EntityId, int]
    alive*: HashSet[EntityId]
    dead*: seq[int]
    data*: seq[T]
    cache*: seq[(EntityId, T)]  # Cache for storing entities during scene transitions

proc init*[T](_: typedesc[EntityBuffer[T]]): EntityBuffer[T] =
  ## Initialize an EntityBuffer with empty collections
  result = EntityBuffer[T]()
  result.entityMap = initTable[EntityId, int]()
  result.alive = initHashSet[EntityId]()
  result.dead = newSeq[int]()
  result.data = newSeq[T]()
  result.cache = newSeq[(EntityId, T)]()

proc `$`*(eid: EntityId): string = $Oid(eid)
proc hash*(eid: EntityId): Hash {.borrow.}
proc `==`*(a, b: EntityId): bool {.borrow.}

proc genEntityId*(): EntityId =
  result = EntityId(genOid())

proc spawn*[T](entityBuffer: EntityBuffer[T], entity: T): EntityId =
  result = genEntityId()
  if entityBuffer.dead.len == 0:
    let index = entityBuffer.data.len
    entityBuffer.data.add(entity)
    entityBuffer.entityMap[result] = index
    entityBuffer.alive.incl(result)
  else:
    # Reuse dead slot
    let index = entityBuffer.dead.pop()
    entityBuffer.data[index] = entity
    entityBuffer.entityMap[result] = index
    entityBuffer.alive.incl(result)

proc spawn*[S, T](entitySystem: S, entity: T): EntityId =
  var buffers = entitySystem.buffers
  for name, field in fieldPairs(buffers):
    when field is EntityBuffer[T]:
      var buffer = cast[EntityBuffer[T]](field)
      return buffer.spawn(entity)

proc get*[S, T](entitySystem: var S, entityId: EntityId, _: typedesc[T]): var T =
  ## Get a mutable reference to an entity by ID
  var buffers = entitySystem.buffers
  for name, field in fieldPairs(buffers):
    when field is EntityBuffer[T]:
      var buffer = cast[EntityBuffer[T]](field)
      if buffer.entityMap.hasKey(entityId):
        let index = buffer.entityMap[entityId]
        return buffer.data[index]
  raise newException(KeyError, "Entity not found: " & $entityId)

proc get*[S, T](entitySystem: S, entityId: EntityId, _: typedesc[T]): T =
  ## Get an immutable entity by ID
  var buffers = entitySystem.buffers
  for name, field in fieldPairs(buffers):
    when field is EntityBuffer[T]:
      let buffer = cast[EntityBuffer[T]](field)
      if buffer.entityMap.hasKey(entityId):
        let index = buffer.entityMap[entityId]
        return buffer.data[index]
  raise newException(KeyError, "Entity not found: " & $entityId)

proc has*[S, T](entitySystem: S, entityId: EntityId, _: typedesc[T]): bool =
  ## Check if an entity of type T exists with the given ID
  var buffers = entitySystem.buffers
  for name, field in fieldPairs(buffers):
    when field is EntityBuffer[T]:
      let buffer = cast[EntityBuffer[T]](field)
      return buffer.alive.contains(entityId) and buffer.entityMap.hasKey(entityId)
  return false

proc kill*[T](buffer: EntityBuffer[T], entityId: EntityId) =
  ## Remove an entity from the buffer, freeing its slot for reuse
  if buffer.alive.contains(entityId):
    let index = buffer.entityMap[entityId]
    buffer.alive.excl(entityId)
    buffer.entityMap.del(entityId)
    buffer.dead.add(index)

proc killAll*[T](buffer: EntityBuffer[T]) =
  ## Remove all entities from the buffer and reset it
  buffer.alive.clear()
  buffer.entityMap.clear()
  buffer.dead.setLen(0)
  buffer.data.setLen(0)

proc pushToCache*[T](buffer: EntityBuffer[T]) =
  ## Push all alive entities to cache and clear the buffer
  ## Used to temporarily store entities during scene transitions
  ##
  ## Example workflow:
  ##   # Before entering combat
  ##   entitySystem.pushAllToCache()  # Save all entities
  ##   scenes.pushScene("CombatScene")
  ##
  ##   # In CombatScene: spawn combat entities, do combat...
  ##
  ##   # After combat ends
  ##   # Combat entities are killed/cleaned up
  ##   scenes.popScene()  # Back to game scene
  ##
  ##   # In game scene load:
  ##   if entitySystem.hasCachedEntities():
  ##     entitySystem.popAllFromCache()  # Restore pre-combat state
  buffer.cache.setLen(0)

  # Copy all alive entities to cache using pairs iterator on entityMap
  for id, index in buffer.entityMap.pairs:
    if buffer.alive.contains(id):
      buffer.cache.add((id, buffer.data[index]))

  # Clear the buffer
  buffer.alive.clear()
  buffer.entityMap.clear()
  buffer.data.setLen(0)
  buffer.dead.setLen(0)

proc popFromCache*[T](buffer: EntityBuffer[T]) =
  ## Restore entities from cache back into the buffer
  ## Used to restore entities after scene transitions
  for (id, entity) in buffer.cache:
    let index = buffer.data.len
    buffer.data.add(entity)
    buffer.entityMap[id] = index
    buffer.alive.incl(id)

  # Clear cache after restoring
  buffer.cache.setLen(0)

proc hasCachedEntities*[T](buffer: EntityBuffer[T]): bool =
  ## Check if the buffer has any cached entities
  buffer.cache.len > 0

macro hasMatching*(entitySystem: typed, entityId: typed, conceptType: typed): bool =
  ## Check if entity with given ID exists and satisfies the concept
  ## Usage: entitySystem.hasMatching(entityId, IsCharacter)
  var checks = newStmtList()
  let foundVar = genSym(nskVar, "found")

  for i in 0 ..< entityTypes.len:
    let entityType = entityTypes[i]
    checks.add(quote do:
      when `entityType` is `conceptType`:
        if `entitySystem`.has(`entityId`, `entityType`):
          `foundVar` = true
    )

  result = quote do:
    block:
      var `foundVar` = false
      `checks`
      `foundVar`

macro withMatching*(entitySystem: typed, entityId: typed, conceptType: typed, varName: untyped, body: untyped): untyped =
  ## Execute code block with entity if it matches the concept
  ## Usage:
  ##   entitySystem.withMatching(entityId, IsCharacter, npc):
  ##     # use npc here
  var checks = newStmtList()
  let foundVar = genSym(nskVar, "found")

  for i in 0 ..< entityTypes.len:
    let entityType = entityTypes[i]
    checks.add(quote do:
      when `entityType` is `conceptType`:
        if `entitySystem`.has(`entityId`, `entityType`):
          let `varName` = `entitySystem`.get(`entityId`, `entityType`)
          `body`
          `foundVar` = true
    )

  result = quote do:
    block:
      var `foundVar` = false
      `checks`
      if not `foundVar`:
        raise newException(KeyError, "No entity matching concept found: " & $`entityId`)

type
  HasEntityBuffers* = concept e
    e.buffers is object

iterator items*[T](buffer: EntityBuffer[T]): T =
  ## Iterate over all entities in a specific buffer
  for entity in buffer.data:
    yield entity

iterator items*[S, T](entitySystem: S, _: typedesc[T]): T =
  ## Iterate over all entities of type T in the entity system
  ## Usage: for player in entitySystem.items(Player): ...
  var buffers = entitySystem.buffers
  for name, field in fieldPairs(buffers):
    when field is EntityBuffer[T]:
      var buffer = cast[EntityBuffer[T]](field)
      for entity in buffer.data:
        yield entity

iterator mitems*[T](buffer: EntityBuffer[T]): var T =
  ## Iterate over all entities in a specific buffer (mutable)
  for entity in buffer.data.mitems:
    yield entity

iterator mitems*[S, T](entitySystem: var S, _: typedesc[T]): var T =
  ## Iterate over all entities of type T in the entity system (mutable)
  ## Usage: for player in entitySystem.mitems(Player): ...
  var buffers = entitySystem.buffers
  for name, field in fieldPairs(buffers):
    when field is EntityBuffer[T]:
      var buffer = cast[EntityBuffer[T]](field)
      for entity in buffer.data.mitems:
        yield entity

macro matching*(entitySystem: typed, varName: untyped, conceptType: typed, body: untyped): untyped =
  ## Iterate over all entities that match a concept or type predicate
  ## Injects both the entity variable and an 'entityId' variable
  ##
  ## Usage:
  ##   matching(entitySystem, entity, IsSpatial):
  ##     echo entityId, ": ", entity.pos
  ##
  ## This generates code that checks each entity type against the concept
  ## and iterates over all matching buffers

  result = newStmtList()
  var checks = newStmtList()
  let entityIdVar = ident("entityId")

  for i in 0 ..< entityTypes.len:
    let
      entityType = entityTypes[i]
      buffersVar = ident("buffers" & $i)
      idVar = ident("id" & $i)
      indexVar = ident("index" & $i)

    checks.add(quote do:
      block:
        var `buffersVar` = `entitySystem`.buffers
        for name, field in fieldPairs(`buffersVar`):
          when field is EntityBuffer[`entityType`]:
            when `entityType` is `conceptType`:
              let buffer = cast[EntityBuffer[`entityType`]](field)
              for `idVar`, `indexVar` in buffer.entityMap.pairs:
                let `entityIdVar` {.inject.} = `idVar`
                let `varName` {.inject.} = buffer.data[`indexVar`]
                `body`
    )

  result.add(checks)

macro matchingMut*(entitySystem: typed, varName: untyped, conceptType: typed, body: untyped): untyped =
  ## Iterate over all entities that match a concept or type predicate (mutable)
  ## Injects both the entity variable and an 'entityId' variable
  ##
  ## Usage:
  ##   matchingMut(entitySystem, entity, IsSpatial):
  ##     echo entityId, ": ", entity.pos
  ##     entity.pos = vec2(0, 0)

  result = newStmtList()
  var checks = newStmtList()
  let entityIdVar = ident("entityId")

  for i in 0 ..< entityTypes.len:
    let
      entityType = entityTypes[i]
      buffersVar = ident("buffers" & $i)
      idVar = ident("id" & $i)
      indexVar = ident("index" & $i)

    checks.add(quote do:
      block:
        var `buffersVar` = `entitySystem`.buffers
        for name, field in fieldPairs(`buffersVar`):
          when field is EntityBuffer[`entityType`]:
            when `entityType` is `conceptType`:
              var buffer = cast[EntityBuffer[`entityType`]](field)
              for `idVar`, `indexVar` in buffer.entityMap.pairs:
                let `entityIdVar` {.inject.} = `idVar`
                # Use mitem to get mutable reference, not a copy
                template `varName`(): untyped {.inject.} = buffer.data[`indexVar`]
                `body`
    )

  result.add(checks)

macro each*(entitySystem: typed, types: varargs[typed], body: untyped): untyped =
  ## Iterate over combinations of entities
  ## For same type: iterates unique combinations (i < j < k)
  ## For different types: iterates full Cartesian product
  ##
  ## Usage:
  ##   each(entitySystem, Player, Player):
  ##     echo a.pos, " vs ", b.pos
  ##
  ##   each(entitySystem, Player, Enemy, Bullet):
  ##     echo a.pos, b.pos, c.pos

  var stmts = newStmtList()

  let numTypes = types.len
  if numTypes == 0:
    error("each requires at least one type")

  let varNames = "abcdefghijklmnopqrstuvwxyz"
  if numTypes > varNames.len:
    error("each supports up to " & $varNames.len & " entity types")

  var bufferIdents = newSeq[NimNode](numTypes)
  var typeToBuffer = newSeq[(string, NimNode)]()

  for i in 0 ..< numTypes:
    let typ = types[i]
    let typeName = typ.repr

    var existingBuffer: NimNode = nil
    for (tName, bufIdent) in typeToBuffer:
      if tName == typeName:
        existingBuffer = bufIdent
        break

    if existingBuffer.isNil:
      let bufferIdent = ident("buffer" & $typeToBuffer.len)
      bufferIdents[i] = bufferIdent
      typeToBuffer.add((typeName, bufferIdent))
      let buffersIdent = ident("buffers" & $typeToBuffer.len)
      stmts.add(quote do:
        var `bufferIdent`: EntityBuffer[`typ`]
        block:
          var `buffersIdent` = `entitySystem`.buffers
          for name, field in fieldPairs(`buffersIdent`):
            when field is EntityBuffer[`typ`]:
              `bufferIdent` = cast[EntityBuffer[`typ`]](field)
              break
      )
    else:
      bufferIdents[i] = existingBuffer

  var loopBody = body
  var typeGroups = newSeq[seq[int]](numTypes)
  for i in 0 ..< numTypes:
    typeGroups[i] = @[i]
    for j in 0 ..< i:
      if types[i].repr == types[j].repr:
        typeGroups[j].add(i)
        typeGroups[i] = @[]
        break

  for i in countdown(numTypes - 1, 0):
    let varName = ident($varNames[i])
    let indexName = ident("idx" & $i)
    let bufferIdent = bufferIdents[i]

    var startIdx: NimNode
    var prevSameTypeIdx = -1
    for j in 0 ..< i:
      if types[j].repr == types[i].repr:
        prevSameTypeIdx = j

    if prevSameTypeIdx >= 0:
      let prevIndexName = ident("idx" & $prevSameTypeIdx)
      startIdx = quote do:
        `prevIndexName` + 1
    else:
      startIdx = newLit(0)
    loopBody = quote do:
      for `indexName` in `startIdx` ..< `bufferIdent`.data.len:
        let `varName` {.inject.} = `bufferIdent`.data[`indexName`]
        `loopBody`
  stmts.add(loopBody)
  result = newStmtList(newBlockStmt(stmts))

macro eachMut*(entitySystem: typed, types: varargs[typed], body: untyped): untyped =
  ## Iterate over combinations of entities
  ## Same as each() but yields var references

  var stmts = newStmtList()

  let numTypes = types.len
  if numTypes == 0:
    error("eachMut requires at least one type")

  let varNames = "abcdefghijklmnopqrstuvwxyz"
  if numTypes > varNames.len:
    error("eachMut supports up to " & $varNames.len & " entity types")

  var bufferIdents = newSeq[NimNode](numTypes)
  var typeToBuffer = newSeq[(string, NimNode)]()

  for i in 0 ..< numTypes:
    let typ = types[i]
    let typeName = typ.repr

    var existingBuffer: NimNode = nil
    for (tName, bufIdent) in typeToBuffer:
      if tName == typeName:
        existingBuffer = bufIdent
        break

    if existingBuffer.isNil:
      let bufferIdent = ident("buffer" & $typeToBuffer.len)
      bufferIdents[i] = bufferIdent
      typeToBuffer.add((typeName, bufferIdent))
      let buffersIdent = ident("buffers" & $typeToBuffer.len)
      stmts.add(quote do:
        var `bufferIdent`: EntityBuffer[`typ`]
        block:
          var `buffersIdent` = `entitySystem`.buffers
          for name, field in fieldPairs(`buffersIdent`):
            when field is EntityBuffer[`typ`]:
              `bufferIdent` = cast[EntityBuffer[`typ`]](field)
              break
      )
    else:
      bufferIdents[i] = existingBuffer

  var loopBody = body
  for i in countdown(numTypes - 1, 0):
    let 
      varName = ident($varNames[i])
      indexName = ident("idx" & $i)
      bufferIdent = bufferIdents[i]
    var startIdx: NimNode
    var prevSameTypeIdx = -1
    for j in 0 ..< i:
      if types[j].repr == types[i].repr:
        prevSameTypeIdx = j
    if prevSameTypeIdx >= 0:
      let prevIndexName = ident("idx" & $prevSameTypeIdx)
      startIdx = quote do:
        `prevIndexName` + 1
    else:
      startIdx = newLit(0)
    loopBody = quote do:
      for `indexName` in `startIdx` ..< `bufferIdent`.data.len:
        var `varName` {.inject.} = `bufferIdent`.data[`indexName`]
        `loopBody`
  stmts.add(loopBody)
  result = newStmtList(newBlockStmt(stmts))

macro startEntityBuffer*(types: varargs[untyped]) =
  var recList = nnkRecList.newTree()

  for typ in types:
    let typeName = $typ
    let fieldName = ident(typeName.toLowerAscii & "s")

    # Build field definition: fieldName*: EntityBuffer[typ]
    recList.add nnkIdentDefs.newTree(
      nnkPostfix.newTree(ident("*"), fieldName),
      nnkBracketExpr.newTree(ident("EntityBuffer"), typ),
      newEmptyNode()
    )

  # Build EntityBuffers type manually
  let entityBuffersType = nnkTypeDef.newTree(
    nnkPostfix.newTree(ident("*"), ident("EntityBuffers")),
    newEmptyNode(),
    nnkObjectTy.newTree(
      newEmptyNode(),
      newEmptyNode(),
      recList
    )
  )

  # Build EntitySystem type using quote and manual combination
  let buffersField = nnkIdentDefs.newTree(
    nnkPostfix.newTree(ident("*"), ident("buffers")),
    ident("EntityBuffers"),
    newEmptyNode()
  )

  let entitySystemType = nnkTypeDef.newTree(
    nnkPostfix.newTree(ident("*"), ident("EntitySystem")),
    newEmptyNode(),
    nnkObjectTy.newTree(
      newEmptyNode(),
      newEmptyNode(),
      nnkRecList.newTree(buffersField)
    )
  )

  result = nnkStmtList.newTree(
    nnkTypeSection.newTree(entityBuffersType),
    nnkTypeSection.newTree(entitySystemType)
  )

macro entityBlock*(typeDefs: untyped): untyped =
  result = typeDefs
  expectKind(typeDefs, nnkTypeSection)

  for typeDef in typeDefs:
    if typeDef.kind == nnkTypeDef:
      let typeName = if typeDef[0].kind == nnkPostfix:
        typeDef[0][1]  # Skip the * postfix
      else:
        typeDef[0]

      entityTypes.add(typeName)

macro entities*(typeDefs: untyped): untyped =
  # Handle both direct type sections and statement lists containing type sections
  var typeSection = typeDefs
  if typeDefs.kind == nnkStmtList and typeDefs.len > 0 and typeDefs[0].kind == nnkTypeSection:
    typeSection = typeDefs[0]
    result = typeDefs
  else:
    expectKind(typeDefs, nnkTypeSection)
    result = typeDefs

  for typeDef in typeSection:
    if typeDef.kind == nnkTypeDef:
      var typeName: NimNode
      var hasEntityPragma = false

      if typeDef[0].kind == nnkPragmaExpr:
        typeName = typeDef[0][0]
        let pragmas = typeDef[0][1]

        for pragma in pragmas:
          if pragma.kind == nnkIdent and $pragma == "entity":
            hasEntityPragma = true
            break
      else:
        typeName = typeDef[0]

      if typeName.kind == nnkPostfix:
        typeName = typeName[1]

      # Add to entityTypes if it has the entity pragma OR if no pragma checking needed
      if hasEntityPragma:
        entityTypes.add(typeName)

macro createEntitySystem*(): untyped =
  result = newCall(ident("startEntityBuffer"))
  for i in 0 ..< entityTypes.len:
    result.add(entityTypes[i])

macro initEntitySystem*(): untyped =
  # Generate initialization statements for each buffer
  var initStmts = newStmtList()
  for i in 0 ..< entityTypes.len:
    let typ = entityTypes[i]
    let typeName = $typ
    let fieldName = ident(typeName.toLowerAscii & "s")

    initStmts.add quote do:
      result.buffers.`fieldName` = EntityBuffer[`typ`].init()

  result = quote do:
    proc init*(T: typedesc[EntitySystem]): EntitySystem =
      result = EntitySystem()
      `initStmts`

macro generateEntitySystem*(types: varargs[untyped]): untyped =
  ## Generate entity system from registered entity types
  ## Usage: generateEntitySystem() - uses types registered with {.entity.} pragma
  ## Or: generateEntitySystem(Player, Enemy, Item) - explicit types

  var useTypes: seq[NimNode]

  if types.len > 0:
    for typ in types:
      useTypes.add(typ)
  else:
    for i in 0 ..< entityTypes.len:
      useTypes.add(entityTypes[i])
  if useTypes.len == 0:
    error("No entity types found. Either mark types with {.entity.} or pass them to generateEntitySystem()")

  # Build the startEntityBuffer call with dynamic types
  var createCall = newCall(ident("startEntityBuffer"))
  for typ in useTypes:
    createCall.add(typ)

  result = quote do:
    `createCall`
    initEntitySystem()

macro pushAllToCache*(entitySystem: typed): untyped =
  ## Push all alive entities in all buffers to cache
  ## Usage: entitySystem.pushAllToCache()
  result = newStmtList()

  for i in 0 ..< entityTypes.len:
    let entityType = entityTypes[i]
    let typeName = ($entityType).toLowerAscii & "s"
    let fieldIdent = ident(typeName)

    result.add(quote do:
      `entitySystem`.buffers.`fieldIdent`.pushToCache()
    )

macro popAllFromCache*(entitySystem: typed): untyped =
  ## Restore all entities from cache in all buffers
  ## Usage: entitySystem.popAllFromCache()
  result = newStmtList()

  for i in 0 ..< entityTypes.len:
    let entityType = entityTypes[i]
    let typeName = ($entityType).toLowerAscii & "s"
    let fieldIdent = ident(typeName)

    result.add(quote do:
      `entitySystem`.buffers.`fieldIdent`.popFromCache()
    )

macro kill*(entitySystem: typed, entityId: typed): untyped =
  ## Kill the entity with the given ID, searching all buffers
  ## Usage: entitySystem.kill(entityId)
  result = newStmtList()

  for i in 0 ..< entityTypes.len:
    let entityType = entityTypes[i]
    let typeName = ($entityType).toLowerAscii & "s"
    let fieldIdent = ident(typeName)

    result.add(quote do:
      `entitySystem`.buffers.`fieldIdent`.kill(`entityId`)
    )

macro killAll*(entitySystem: typed): untyped =
  ## Kill all entities in all buffers
  ## Usage: entitySystem.killAll()
  result = newStmtList()

  for i in 0 ..< entityTypes.len:
    let entityType = entityTypes[i]
    let typeName = ($entityType).toLowerAscii & "s"
    let fieldIdent = ident(typeName)

    result.add(quote do:
      `entitySystem`.buffers.`fieldIdent`.killAll()
    )

macro killAllExcept*(entitySystem: typed, exceptIds: typed): untyped =
  ## Kill all entities in all buffers except those with IDs in exceptIds
  ## Usage: entitySystem.killAllExcept(keepIds)  # where keepIds is a seq/openArray of EntityId
  result = newStmtList()

  for i in 0 ..< entityTypes.len:
    let entityType = entityTypes[i]
    let typeName = ($entityType).toLowerAscii & "s"
    let fieldIdent = ident(typeName)

    result.add(quote do:
      block:
        var toKill: seq[EntityId]
        for id in `entitySystem`.buffers.`fieldIdent`.alive:
          var keep = false
          for exceptId in `exceptIds`:
            if id == exceptId:
              keep = true
              break
          if not keep:
            toKill.add(id)
        for id in toKill:
          `entitySystem`.buffers.`fieldIdent`.kill(id)
    )

macro hasCachedEntities*(entitySystem: typed): bool =
  ## Check if any buffer has cached entities
  ## Usage: if entitySystem.hasCachedEntities(): ...
  result = newStmtList()
  let resultVar = genSym(nskVar, "hasCached")

  result.add(quote do:
    var `resultVar` = false
  )

  for i in 0 ..< entityTypes.len:
    let entityType = entityTypes[i]
    let typeName = ($entityType).toLowerAscii & "s"
    let fieldIdent = ident(typeName)

    result.add(quote do:
      if `entitySystem`.buffers.`fieldIdent`.hasCachedEntities():
        `resultVar` = true
    )

  result.add(quote do:
    `resultVar`
  )

macro forwardFields*(conceptType: untyped, componentField: untyped, fields: varargs[untyped]): untyped =
  ## Generates getter and setter procs that forward field access from a concept to its component
  ##
  ## Example:
  ##   forwardFields(IsSpatial, spatial, pos)
  ##
  ## Generates:
  ##   proc pos*(sp: IsSpatial): auto {.inline.} = sp.spatial.pos
  ##   proc `pos=`*(sp: var IsSpatial, value: auto) {.inline.} = sp.spatial.pos = value

  result = newStmtList()

  for field in fields:
    let fieldIdent = field
    let setterIdent = ident($field & "=")

    let getter = quote do:
      proc `fieldIdent`*(sp: `conceptType`): auto {.inline.} =
        sp.`componentField`.`fieldIdent`

    let setter = quote do:
      proc `setterIdent`*(sp: var `conceptType`, value: auto) {.inline.} =
        sp.`componentField`.`fieldIdent` = value

    result.add(getter)
    result.add(setter)

macro genComponent*(typeName: untyped, fields: varargs[untyped]): untyped =
  ## Generates a concept type and field forwarding for a component
  ##
  ## Example:
  ##   genComponent(Spatial, pos)
  ##
  ## Generates:
  ##   type
  ##     IsSpatial* = concept t
  ##       t.spatial is Spatial
  ##   forwardFields(IsSpatial, spatial, pos)

  let typeNameStr = $typeName
  let conceptName = ident("Is" & typeNameStr)
  let fieldName = ident(typeNameStr[0].toLowerAscii & typeNameStr[1..^1])

  result = newStmtList()

  # Try generating concept with quote do
  let tIdent = ident("t")
  result.add quote do:
    type
      `conceptName`* = concept `tIdent`
        `tIdent`.`fieldName` is `typeName`

  # Generate field forwarding if fields are provided
  if fields.len > 0:
    let forwardCall = newCall(ident("forwardFields"), conceptName, fieldName)
    for field in fields:
      forwardCall.add(field)
    result.add(forwardCall)
