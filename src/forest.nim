## Forest - Entity Component System Library
##
## Usage Examples:
##
## **1. Manual approach - explicitly list all types:**
## ```nim
## type
##   Player = object
##   Enemy = object
##   Bullet = object
##
## startEntityBuffer(Player, Enemy, Bullet)
## ```
##
## **2. Block registration - register all types in a block:**
## ```nim
## entityBlock:
##   type
##     Player* = object
##     Enemy* = object
##     Bullet* = object
##
## createEntitySystem()
## ```
##
## **3. Pragma registration - only register marked types:**
## ```nim
## entities:
##   type
##     Player {.entity.} = object
##     Enemy {.entity.} = object
##     NotAnEntity = object  # Won't be registered
##
## createEntitySystem()
## ```
##
## All approaches generate:
## ```nim
## type
##   EntityBuffers = object
##     players*: EntityBuffer[Player]
##     enemys*: EntityBuffer[Enemy]
##     bullets*: EntityBuffer[Bullet]
##
##   EntitySystem = object
##     buffers*: EntityBuffers
## ```

import std/[macros, strutils, macrocache]

# Macro cache to store registered entity types
const entityTypes = CacheSeq"ForestEntityTypes"

# Define entity as a pragma marker
template entity* {.pragma.}

type
  EntityBuffer*[T] = object
    data*: seq[T]

macro startEntityBuffer*(types: varargs[untyped]) =
  ## Generates EntityBuffers type with fields for each entity type.
  ## Each type T becomes a field named `Ts: EntityBuffer[T]`
  # Build the record list for EntityBuffers fields
  var recList = newNimNode(nnkRecList)

  for typ in types:
    # Create pluralized field name (e.g., Player -> players)
    let typeName = $typ
    let fieldName = ident(typeName.toLowerAscii & "s")

    # Create EntityBuffer[Type] type expression
    let fieldType = newNimNode(nnkBracketExpr).add(
      ident("EntityBuffer"),
      typ
    )

    # Create public field definition: fieldName*: EntityBuffer[Type]
    let fieldDef = newNimNode(nnkIdentDefs).add(
      newNimNode(nnkPostfix).add(ident("*"), fieldName),
      fieldType,
      newEmptyNode()
    )

    recList.add(fieldDef)

  # Build the EntityBuffers type definition
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
  ## Block macro to register all entity types in a type section.
  ## Usage:
  ## ```nim
  ## entityBlock:
  ##   type
  ##     Player* = object
  ##     Enemy* = object
  ## ```
  result = typeDefs

  # Process the type section to extract type names
  expectKind(typeDefs, nnkTypeSection)

  for typeDef in typeDefs:
    if typeDef.kind == nnkTypeDef:
      # Get the type name (handle exported types with *)
      let typeName = if typeDef[0].kind == nnkPostfix:
        typeDef[0][1]  # Skip the * postfix
      else:
        typeDef[0]

      # Add to macro cache
      entityTypes.add(typeName)

macro entities*(typeDefs: untyped): untyped =
  ## Processes a type section and registers types marked with {.entity.} pragma.
  ## Usage:
  ## ```nim
  ## entities:
  ##   type
  ##     Player {.entity.} = object
  ##     Enemy {.entity.} = object
  ##     NotAnEntity = object  # Not registered
  ## ```
  result = typeDefs

  # Process the type section
  expectKind(typeDefs, nnkTypeSection)

  for typeDef in typeDefs:
    if typeDef.kind == nnkTypeDef:
      var typeName: NimNode
      var hasEntityPragma = false

      # Check if the type has pragmas
      if typeDef[0].kind == nnkPragmaExpr:
        # Type has pragmas: TypeName {.entity.}
        typeName = typeDef[0][0]
        let pragmas = typeDef[0][1]

        # Look for the entity pragma
        for pragma in pragmas:
          if pragma.kind == nnkIdent and $pragma == "entity":
            hasEntityPragma = true
            break
      else:
        typeName = typeDef[0]

      # Handle exported types (TypeName*)
      if typeName.kind == nnkPostfix:
        typeName = typeName[1]

      # Register if has entity pragma
      if hasEntityPragma:
        entityTypes.add(typeName)

macro createEntitySystem*(): untyped =
  ## Creates EntityBuffers and EntitySystem using all entity types
  ## that were registered with the `entity` macro.
  ##
  ## Must be called after all entity types are registered.
  result = newCall(ident("startEntityBuffer"))

  for i in 0 ..< entityTypes.len:
    result.add(entityTypes[i])

