import unittest
import forest

# Test component types
type
  Position* = object
    x*, y*: float

  Velocity* = object
    dx*, dy*: float

  Health* = object
    current*, max*: int

# Generate component concepts and field forwarding
genComponent(Position, x, y)
genComponent(Velocity, dx, dy)
genComponent(Health, current, max)

# Test entity types
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
    ownerId*: int

generateEntitySystem()

suite "Forest Entity System":
  test "genComponent macro generates concepts":
    # Test that concepts were generated
    var player = Player(
      position: Position(x: 10.0, y: 20.0),
      velocity: Velocity(dx: 1.0, dy: 2.0),
      health: Health(current: 100, max: 100),
      name: "Test Player"
    )

    # Test that player satisfies the concepts
    when compiles(player is IsPosition):
      check true
    else:
      check false

    when compiles(player is IsVelocity):
      check true
    else:
      check false

    when compiles(player is IsHealth):
      check true
    else:
      check false

  test "forwardFields macro generates getters and setters":
    var player = Player(
      position: Position(x: 10.0, y: 20.0),
      velocity: Velocity(dx: 1.0, dy: 2.0),
      health: Health(current: 100, max: 100),
      name: "Test Player"
    )

    # Test getters
    check player.x == 10.0
    check player.y == 20.0
    check player.dx == 1.0
    check player.dy == 2.0
    check player.current == 100
    check player.max == 100

    # Test setters
    player.x = 30.0
    player.y = 40.0
    check player.position.x == 30.0
    check player.position.y == 40.0

    player.dx = 3.0
    player.dy = 4.0
    check player.velocity.dx == 3.0
    check player.velocity.dy == 4.0

    player.current = 50
    check player.health.current == 50

  test "EntitySystem initialization":
    let entitySystem = init(EntitySystem)

    check entitySystem.buffers.players != nil
    check entitySystem.buffers.enemys != nil
    check entitySystem.buffers.projectiles != nil

  test "Entity spawning":
    var entitySystem = init(EntitySystem)

    let player = Player(
      position: Position(x: 0.0, y: 0.0),
      velocity: Velocity(dx: 0.0, dy: 0.0),
      health: Health(current: 100, max: 100),
      name: "Player 1"
    )

    let playerId = entitySystem.spawn(player)
    check $playerId != ""

    # Check that entity was added to buffer
    var found = false
    for p in entitySystem.items(Player):
      if p.name == "Player 1":
        found = true
        break
    check found

  test "Entity iteration":
    var entitySystem = init(EntitySystem)

    # Spawn some entities
    discard entitySystem.spawn(Player(
      position: Position(x: 1.0, y: 1.0),
      velocity: Velocity(dx: 0.0, dy: 0.0),
      health: Health(current: 100, max: 100),
      name: "Player 1"
    ))

    discard entitySystem.spawn(Player(
      position: Position(x: 2.0, y: 2.0),
      velocity: Velocity(dx: 0.0, dy: 0.0),
      health: Health(current: 80, max: 100),
      name: "Player 2"
    ))

    discard entitySystem.spawn(Enemy(
      position: Position(x: 10.0, y: 10.0),
      velocity: Velocity(dx: -1.0, dy: 0.0),
      health: Health(current: 50, max: 50),
      damage: 10
    ))

    # Test iteration over specific type
    var playerCount = 0
    for player in entitySystem.items(Player):
      playerCount += 1
    check playerCount == 2

    var enemyCount = 0
    for enemy in entitySystem.items(Enemy):
      enemyCount += 1
    check enemyCount == 1

  test "Mutable entity iteration":
    var entitySystem = init(EntitySystem)

    discard entitySystem.spawn(Player(
      position: Position(x: 0.0, y: 0.0),
      velocity: Velocity(dx: 1.0, dy: 1.0),
      health: Health(current: 100, max: 100),
      name: "Player 1"
    ))

    # Modify entities through mutable iteration
    for player in entitySystem.mitems(Player):
      player.position.x += player.velocity.dx
      player.position.y += player.velocity.dy

    # Verify modifications
    for player in entitySystem.items(Player):
      check player.position.x == 1.0
      check player.position.y == 1.0

  test "Concept-based matching":
    var entitySystem = init(EntitySystem)

    discard entitySystem.spawn(Player(
      position: Position(x: 5.0, y: 5.0),
      velocity: Velocity(dx: 0.0, dy: 0.0),
      health: Health(current: 100, max: 100),
      name: "Player 1"
    ))

    discard entitySystem.spawn(Enemy(
      position: Position(x: 15.0, y: 15.0),
      velocity: Velocity(dx: 0.0, dy: 0.0),
      health: Health(current: 50, max: 50),
      damage: 10
    ))

    discard entitySystem.spawn(Projectile(
      position: Position(x: 7.0, y: 7.0),
      velocity: Velocity(dx: 2.0, dy: 0.0),
      ownerId: 1
    ))

    # Test matching with IsPosition concept
    var positionCount = 0
    matching(entitySystem, entity, IsPosition):
      positionCount += 1
      check entity.x >= 0.0

    check positionCount == 3  # All entities have position

    # Test matching with IsHealth concept
    var healthCount = 0
    matching(entitySystem, entity, IsHealth):
      healthCount += 1
      check entity.current > 0

    check healthCount == 2  # Player and Enemy have health

  test "Mutable concept-based matching":
    var entitySystem = init(EntitySystem)

    discard entitySystem.spawn(Player(
      position: Position(x: 0.0, y: 0.0),
      velocity: Velocity(dx: 1.0, dy: 0.0),
      health: Health(current: 100, max: 100),
      name: "Player 1"
    ))

    discard entitySystem.spawn(Projectile(
      position: Position(x: 10.0, y: 10.0),
      velocity: Velocity(dx: 5.0, dy: 0.0),
      ownerId: 1
    ))

    # Update all entities with velocity
    matchingMut(entitySystem, entity, IsVelocity):
      entity.x = entity.x + entity.dx

    # Verify updates
    for player in entitySystem.items(Player):
      check player.position.x == 1.0

    for projectile in entitySystem.items(Projectile):
      check projectile.position.x == 15.0

  test "Each macro for entity combinations":
    var entitySystem = init(EntitySystem)

    discard entitySystem.spawn(Player(
      position: Position(x: 0.0, y: 0.0),
      velocity: Velocity(dx: 0.0, dy: 0.0),
      health: Health(current: 100, max: 100),
      name: "Player 1"
    ))

    discard entitySystem.spawn(Player(
      position: Position(x: 10.0, y: 0.0),
      velocity: Velocity(dx: 0.0, dy: 0.0),
      health: Health(current: 100, max: 100),
      name: "Player 2"
    ))

    discard entitySystem.spawn(Enemy(
      position: Position(x: 5.0, y: 5.0),
      velocity: Velocity(dx: 0.0, dy: 0.0),
      health: Health(current: 50, max: 50),
      damage: 10
    ))

    # Test Player-Player combinations (should get unique pairs)
    var pairCount = 0
    each(entitySystem, Player, Player):
      pairCount += 1
      check a.name != b.name
    check pairCount == 1  # Only one unique pair (Player1, Player2)

    # Test Player-Enemy combinations (full Cartesian product)
    var combCount = 0
    each(entitySystem, Player, Enemy):
      combCount += 1
    check combCount == 2  # 2 players × 1 enemy
