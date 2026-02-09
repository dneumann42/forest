version       = "0.1.0"
author        = "Developer"
description   = "Forest library"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"

task test, "Run tests":
  exec "nim c -r tests/test_forest.nim"
