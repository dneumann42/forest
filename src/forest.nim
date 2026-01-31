import std/[macros, strutils, macrocache, oids, hashes, tables, sets]

const entityTypes = CacheSeq"ForestEntityTypes"

template entity* {.pragma.}

type
  EntityId* = distinct Oid

  EntityBuffer*[T] = ref object
    entityMap*: Table[EntityId, int]
    alive*: HashSet[EntityId]
    dead*: seq[int]
    data*: seq[T]
    
proc `$`*(eid: EntityId): string = $Oid(eid)
proc hash*(eid: EntityId): Hash {.borrow.}
proc `==`*(a, b: EntityId): bool {.borrow.}

proc genEntityId*(): EntityId =
  result = EntityId(genOid())

proc spawn*[T](entityBuffer: EntityBuffer[T], entity: T): EntityId =
  result = genEntityId()
  if entityBuffer.dead.len == 0:
    entityBuffer.data.add(entity)

proc spawn*[S, T](entitySystem: S, entity: T): EntityId =
  var buffers = entitySystem.buffers
  for name, field in fieldPairs(buffers):
    when field is EntityBuffer[T]:
      var buffer = cast[EntityBuffer[T]](field)
      return buffer.spawn(entity)

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
  ##
  ## Usage:
  ##   matching(entitySystem, entity, IsSpatial):
  ##     echo entity.pos
  ##
  ## This generates code that checks each entity type against the concept
  ## and iterates over all matching buffers

  result = newStmtList()

  # Generate checks for each registered entity type
  var checks = newStmtList()

  for i in 0 ..< entityTypes.len:
    let entityType = entityTypes[i]

    # For each type, check if it matches the concept and iterate if it does
    let buffersVar = ident("buffers" & $i)

    checks.add(quote do:
      block:
        var `buffersVar` = `entitySystem`.buffers
        for name, field in fieldPairs(`buffersVar`):
          when field is EntityBuffer[`entityType`]:
            # Check if this entity type matches the concept
            when `entityType` is `conceptType`:
              let buffer = cast[EntityBuffer[`entityType`]](field)
              for `varName` {.inject.} in buffer.data:
                `body`
    )

  result.add(checks)

macro matchingMut*(entitySystem: typed, varName: untyped, conceptType: typed, body: untyped): untyped =
  ## Iterate over all entities that match a concept or type predicate (mutable)
  ##
  ## Usage:
  ##   matchingMut(entitySystem, entity, IsSpatial):
  ##     entity.pos = vec2(0, 0)

  result = newStmtList()

  # Generate checks for each registered entity type
  var checks = newStmtList()

  for i in 0 ..< entityTypes.len:
    let entityType = entityTypes[i]

    # For each type, check if it matches the concept and iterate if it does
    let buffersVar = ident("buffers" & $i)

    checks.add(quote do:
      block:
        var `buffersVar` = `entitySystem`.buffers
        for name, field in fieldPairs(`buffersVar`):
          when field is EntityBuffer[`entityType`]:
            # Check if this entity type matches the concept
            when `entityType` is `conceptType`:
              var buffer = cast[EntityBuffer[`entityType`]](field)
              for `varName` {.inject.} in buffer.data.mitems:
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
    return

  # Generate variable names: a, b, c, d, etc.
  let varNames = "abcdefghijklmnopqrstuvwxyz"
  if numTypes > varNames.len:
    error("each supports up to " & $varNames.len & " entity types")
    return

  # Create buffer variable names and retrieval statements
  # Track unique types to avoid duplicate buffer retrievals
  var bufferIdents = newSeq[NimNode](numTypes)
  var typeToBuffer = newSeq[(string, NimNode)]()

  # Generate inline buffer retrieval for each unique type
  for i in 0 ..< numTypes:
    let typ = types[i]
    let typeName = typ.repr

    # Check if we already retrieved this type
    var existingBuffer: NimNode = nil
    for (tName, bufIdent) in typeToBuffer:
      if tName == typeName:
        existingBuffer = bufIdent
        break

    if existingBuffer.isNil:
      # First time seeing this type - retrieve it
      let bufferIdent = ident("buffer" & $typeToBuffer.len)
      bufferIdents[i] = bufferIdent
      typeToBuffer.add((typeName, bufferIdent))

      # Generate: var bufferN: EntityBuffer[Type]
      # Then inline fieldPairs loop to find it
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
      # Reuse existing buffer for this type
      bufferIdents[i] = existingBuffer

  # Build nested loops from innermost to outermost
  var loopBody = body

  # Track which types are the same for optimization
  var typeGroups = newSeq[seq[int]](numTypes)
  for i in 0 ..< numTypes:
    typeGroups[i] = @[i]
    for j in 0 ..< i:
      if types[i].repr == types[j].repr:
        typeGroups[j].add(i)
        typeGroups[i] = @[]
        break

  # Generate loops from innermost to outermost
  for i in countdown(numTypes - 1, 0):
    let varName = ident($varNames[i])
    let indexName = ident("idx" & $i)
    let bufferIdent = bufferIdents[i]

    # Determine loop start index
    var startIdx: NimNode

    # If this type appeared before, start from previous index + 1
    var prevSameTypeIdx = -1
    for j in 0 ..< i:
      if types[j].repr == types[i].repr:
        prevSameTypeIdx = j

    if prevSameTypeIdx >= 0:
      # Same type as a previous one - start from previous index + 1 to avoid duplicates
      let prevIndexName = ident("idx" & $prevSameTypeIdx)
      startIdx = quote do:
        `prevIndexName` + 1
    else:
      # Different type or first occurrence - start from 0
      startIdx = newLit(0)

    # Create the for loop
    loopBody = quote do:
      for `indexName` in `startIdx` ..< `bufferIdent`.data.len:
        let `varName` {.inject.} = `bufferIdent`.data[`indexName`]
        `loopBody`

  stmts.add(loopBody)

  # Wrap in a block to isolate variables
  result = newStmtList(newBlockStmt(stmts))

macro eachMut*(entitySystem: typed, types: varargs[typed], body: untyped): untyped =
  ## Iterate over combinations of entities (mutable)
  ## Same as each() but yields var references

  var stmts = newStmtList()

  let numTypes = types.len
  if numTypes == 0:
    error("eachMut requires at least one type")
    return

  # Generate variable names: a, b, c, d, etc.
  let varNames = "abcdefghijklmnopqrstuvwxyz"
  if numTypes > varNames.len:
    error("eachMut supports up to " & $varNames.len & " entity types")
    return

  # Create buffer variable names and retrieval statements
  # Track unique types to avoid duplicate buffer retrievals
  var bufferIdents = newSeq[NimNode](numTypes)
  var typeToBuffer = newSeq[(string, NimNode)]()

  # Generate inline buffer retrieval for each unique type
  for i in 0 ..< numTypes:
    let typ = types[i]
    let typeName = typ.repr

    # Check if we already retrieved this type
    var existingBuffer: NimNode = nil
    for (tName, bufIdent) in typeToBuffer:
      if tName == typeName:
        existingBuffer = bufIdent
        break

    if existingBuffer.isNil:
      # First time seeing this type - retrieve it
      let bufferIdent = ident("buffer" & $typeToBuffer.len)
      bufferIdents[i] = bufferIdent
      typeToBuffer.add((typeName, bufferIdent))

      # Generate: var bufferN: EntityBuffer[Type]
      # Then inline fieldPairs loop to find it
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
      # Reuse existing buffer for this type
      bufferIdents[i] = existingBuffer

  # Build nested loops from innermost to outermost
  var loopBody = body

  # Generate loops from innermost to outermost
  for i in countdown(numTypes - 1, 0):
    let varName = ident($varNames[i])
    let indexName = ident("idx" & $i)
    let bufferIdent = bufferIdents[i]

    # Determine loop start index
    var startIdx: NimNode

    # If this type appeared before, start from previous index + 1
    var prevSameTypeIdx = -1
    for j in 0 ..< i:
      if types[j].repr == types[i].repr:
        prevSameTypeIdx = j

    if prevSameTypeIdx >= 0:
      # Same type as a previous one - start from previous index + 1 to avoid duplicates
      let prevIndexName = ident("idx" & $prevSameTypeIdx)
      startIdx = quote do:
        `prevIndexName` + 1
    else:
      # Different type or first occurrence - start from 0
      startIdx = newLit(0)

    # Create the for loop with var
    loopBody = quote do:
      for `indexName` in `startIdx` ..< `bufferIdent`.data.len:
        var `varName` {.inject.} = `bufferIdent`.data[`indexName`]
        `loopBody`

  stmts.add(loopBody)

  # Wrap in a block to isolate variables
  result = newStmtList(newBlockStmt(stmts))

macro startEntityBuffer*(types: varargs[untyped]) =
  var recList = newNimNode(nnkRecList)

  for typ in types:
    let typeName = $typ
    let fieldName = ident(typeName.toLowerAscii & "s")
    let fieldType = newNimNode(nnkBracketExpr).add(
      ident("EntityBuffer"),
      typ
    )
    let fieldDef = newNimNode(nnkIdentDefs).add(
      newNimNode(nnkPostfix).add(ident("*"), fieldName),
      fieldType,
      newEmptyNode()
    )
    recList.add(fieldDef)

  let entityBuffersType = newNimNode(nnkTypeDef).add(
    newNimNode(nnkPostfix).add(ident("*"), ident("EntityBuffers")),
    newEmptyNode(),
    newNimNode(nnkObjectTy).add(
      newEmptyNode(),
      newEmptyNode(),
      recList
    )
  )

  result = newNimNode(nnkStmtList).add(
    newNimNode(nnkTypeSection).add(entityBuffersType),
    newNimNode(nnkTypeSection).add(
      newNimNode(nnkTypeDef).add(
        newNimNode(nnkPostfix).add(ident("*"), ident("EntitySystem")),
        newEmptyNode(),
        newNimNode(nnkObjectTy).add(
          newEmptyNode(),
          newEmptyNode(),
          newNimNode(nnkRecList).add(
            newNimNode(nnkIdentDefs).add(
              newNimNode(nnkPostfix).add(ident("*"), ident("buffers")),
              ident("EntityBuffers"),
              newEmptyNode()
            )
          )
        )
      )
    )
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
    let bufferType = newNimNode(nnkBracketExpr).add(
      ident("EntityBuffer"),
      typ
    )
    initStmts.add(newAssignment(
      newDotExpr(newDotExpr(ident("result"), ident("buffers")), fieldName),
      newCall(bufferType)
    ))

  # Build the proc definition manually
  result = newProc(
    name = postfix(ident("init"), "*"),
    params = [
      ident("EntitySystem"),
      newIdentDefs(ident("T"), newNimNode(nnkBracketExpr).add(ident("typedesc"), ident("EntitySystem")))
    ],
    body = newStmtList(
      newAssignment(ident("result"), newCall(ident("EntitySystem"))),
      initStmts
    )
  )

template generateEntitySystem*() =
  createEntitySystem()
  initEntitySystem()

