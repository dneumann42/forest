# Forest

A lightweight composable entity system for Nim.

> **⚠️ Development Status**: This library is under active development and the API may change.

## What is Forest?

Forest is an Entity Component System (ECS) that provides entity management and component composition. It uses Nim's concept system to create type-safe, composable entities without runtime overhead.

## Features

- Composable entity definitions using components
- Automatic concept generation for component queries
- Field forwarding for direct component access
- Type-safe entity iteration
- Entity caching and snapshots

## Installation

```nim
requires "forest"
```

## Basic Usage

### Define Components

Components are data-only objects that define entity properties:

```nim
import forest

type
  Position* = object
    x*, y*: float

  Velocity* = object
    dx*, dy*: float

  Health* = object
    current*, max*: int
```

### Generate Component Concepts

The `genComponent` macro creates concepts and field forwarding:

```nim
genComponent(Position, x, y)
genComponent(Velocity, dx, dy)
genComponent(Health, current, max)
```

This generates:
- `IsPosition` concept for any entity with a `position: Position` field
- Getter/setter procs so you can write `entity.x` instead of `entity.position.x`

### Define Entities

Entities are compositions of components marked with `{.entity.}`:

```nim
type
  Player* {.entity.} = object
    position*: Position
    velocity*: Velocity
    health*: Health
    name*: string

  Enemy* {.entity.} = object
    position*: Position
    velocity*: Velocity
    health*: Health
    damage*: int

  Projectile* {.entity.} = object
    position*: Position
    velocity*: Velocity
```

### Generate the Entity System

```nim
generateEntitySystem()
```

This creates the `EntitySystem` type that manages all defined entities.

### Create and Manage Entities

```nim
var entitySystem = init(EntitySystem)

# Spawn entities
let playerId = entitySystem.spawn(Player(
  position: Position(x: 0, y: 0),
  velocity: Velocity(dx: 0, dy: 0),
  health: Health(current: 100, max: 100),
  name: "Hero"
))

let enemyId = entitySystem.spawn(Enemy(
  position: Position(x: 50, y: 50),
  velocity: Velocity(dx: -1, dy: 0),
  health: Health(current: 50, max: 50),
  damage: 10
))
```

### Iterate Over Entities

Use concepts to iterate over entities with specific components:

```nim
# Iterate with concepts (mutable)
matchingMut(entitySystem, entity, IsPosition):
  entity.x += 1.0

# Iterate with concepts (immutable)
matching(entitySystem, entity, IsPosition):
  echo "Entity at: ", entity.x, ", ", entity.y

# Iterate specific entity types
for player in entitySystem.mitems(Player):
  player.x += player.dx
  player.y += player.dy

for enemy in entitySystem.items(Enemy):
  echo "Enemy health: ", enemy.health.current
```

### Combined Concepts

```nim
type IsMovable* = IsPosition and IsVelocity

matchingMut(entitySystem, entity, IsMovable):
  entity.x += entity.dx
  entity.y += entity.dy
```

### Entity Caching

Forest supports caching entity states for snapshots:

```nim
# Save current state
entitySystem.pushAllToCache()

# Modify entities
matchingMut(entitySystem, entity, IsPosition):
  entity.x += 10

# Restore previous state
entitySystem.popAllFromCache()
```

## API Reference

### Macros

- `genComponent(Type, field1, field2, ...)` - Generate concept and field forwarding
- `generateEntitySystem()` - Generate the EntitySystem type
- `matching(system, varName, Concept, body)` - Iterate immutable
- `matchingMut(system, varName, Concept, body)` - Iterate mutable
- `each(system, Type1, Type2, ..., body)` - Iterate combinations immutable
- `eachMut(system, Type1, Type2, ..., body)` - Iterate combinations mutable

### EntitySystem Methods

- `spawn[T](entity: T): EntityId` - Create a new entity
- `despawn(id: EntityId)` - Remove an entity
- `items[T](): iterator` - Iterate entities of type T (immutable)
- `mitems[T](): iterator` - Iterate entities of type T (mutable)
- `pushAllToCache()` - Save all entity states
- `popAllFromCache()` - Restore saved states
- `hasCachedEntities(): bool` - Check if cache exists

## Example: Physics System

```nim
import forest

type
  Position = object
    x, y: float

  Velocity = object
    dx, dy: float

genComponent(Position, x, y)
genComponent(Velocity, dx, dy)

type
  MovingEntity {.entity.} = object
    position: Position
    velocity: Velocity

generateEntitySystem()

proc updatePhysics(system: var EntitySystem, dt: float) =
  type IsMovable = IsPosition and IsVelocity

  matchingMut(system, entity, IsMovable):
    entity.x += entity.dx * dt
    entity.y += entity.dy * dt

var system = init(EntitySystem)
system.spawn(MovingEntity(
  position: Position(x: 0, y: 0),
  velocity: Velocity(dx: 100, dy: 50)
))

system.updatePhysics(0.016)
```

## License

MIT
