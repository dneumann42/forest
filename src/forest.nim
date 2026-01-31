## Forest - Entity Component System Library
##
## Usage Example:
## ```nim
## # Manual approach:
## type
##   Player = object
##   Enemy = object
##   Bullet = object
##
## startEntityBuffer(Player, Enemy, Bullet)
##
## # Or use the entity pragma for automatic registration:
## entity:
##   type
##     Player* = object
##     Enemy* = object
##     Bullet* = object
##
## createEntitySystem()  # Automatically uses all registered entity types
##
## # Both generate:
## # type
## #   EntityBuffers = object
## #     players*: EntityBuffer[Player]
## #     enemys*: EntityBuffer[Enemy]
## #     bullets*: EntityBuffer[Bullet]
## #
## #   EntitySystem = object
## #     buffers*: EntityBuffers
## ```

import std/[macros, strutils, macrocache]

# Macro cache to store registered entity types
const entityTypes = CacheSeq"ForestEntityTypes"

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

macro entity*(typeDefs: untyped): untyped =
  ## Pragma-like macro to register entity types.
  ## Usage:
  ## ```nim
  ## entity:
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

macro createEntitySystem*(): untyped =
  ## Creates EntityBuffers and EntitySystem using all entity types
  ## that were registered with the `entity` macro.
  ##
  ## Must be called after all entity types are registered.
  var typesList = nnkArgList.newTree()

  for i in 0 ..< entityTypes.len:
    typesList.add(entityTypes[i])

  # Generate call to startEntityBuffer with all registered types
  result = newCall(ident("startEntityBuffer"), typesList)

