import std/[macros, strutils]

type
  EntityBuffer*[T] = object
    data: seq[T]

macro startEntityBuffer*(types: varargs[untyped]) =
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

