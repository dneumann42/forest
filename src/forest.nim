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
  var checks = newStmtList()
  for i in 0 ..< entityTypes.len:
    let 
      entityType = entityTypes[i]
      buffersVar = ident("buffers" & $i)

    checks.add(quote do:
      block:
        var `buffersVar` = `entitySystem`.buffers
        for name, field in fieldPairs(`buffersVar`):
          when field is EntityBuffer[`entityType`]:
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
  var checks = newStmtList()
  for i in 0 ..< entityTypes.len:
    let 
      entityType = entityTypes[i]
      buffersVar = ident("buffers" & $i)

    checks.add(quote do:
      block:
        var `buffersVar` = `entitySystem`.buffers
        for name, field in fieldPairs(`buffersVar`):
          when field is EntityBuffer[`entityType`]:
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

  var createCall = newCall(ident("startEntityBuffer"))
  for typ in useTypes:
    createCall.add(typ)

  result = newStmtList()
  result.add(createCall)
  result.add(newCall(ident("initEntitySystem")))

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
