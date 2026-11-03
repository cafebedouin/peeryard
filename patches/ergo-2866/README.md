# ergoplatform/ergo#2866: two threads close one registered LevelDB at once

`concurrent-close-probe.patch` adds `src/test/scala/scorex/db/ConcurrentCloseProbeSpec.scala` (root project, so the
test JVM loads native leveldbjni; in `avldb`'s test JVM `LDBFactory.factory` can fall back to the pure-Java LevelDB).
The spec opens one temp path twice through `LDBFactory.factory`, so both handles are the same `RegisteredDB`, and two
threads released by a barrier close it; a fresh path per iteration, 2,000 iterations. It prints the factory first: a
run that does not print `leveldbjni` did not test native code.

`concurrent-close-probe-with-fix.patch` is the same spec plus #2866's production change, `git diff
v6.0.10...c0fa65a9b -- avldb/src/main/scala/scorex/db/LDBFactory.scala`, which applies to `v6.0.11` as it is.

Both arms on `v6.0.11` (`ecb8f8a1d`):

    gh workflow run ref-specs.yml -f label=concurrent-close-probe -f specs=scorex.db.ConcurrentCloseProbeSpec \
      -f arms='base:ecb8f8a1d64a467ba788c6e92e62b188c21926ac:patches/ergo-2866/concurrent-close-probe.patch fix:ecb8f8a1d64a467ba788c6e92e62b188c21926ac:patches/ergo-2866/concurrent-close-probe-with-fix.patch'

Expected if a concurrent close double-frees the native handle: the base arm's forked JVM dies with SIGSEGV in
`NativeDB$DBJNI.delete` or `PosixEnv::UnlockFile` and sbt waits on it until the step's time limit; the fix arm prints
`RDBPROBE done n=2000 closeErrors=0`. A probe for evidence, not a regression test.
