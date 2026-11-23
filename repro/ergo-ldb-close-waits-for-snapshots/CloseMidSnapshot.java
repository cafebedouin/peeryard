// Close an LDBVersionedStore while processSnapshot's logic is running, then let processSnapshot release its
// snapshot. One case per JVM (a native crash ends the JVM), with the node jar on the class path so scorex.db.LDBFactory
// loads the native LevelDB (leveldbjni), as `java -jar` does:
//   javac -cp <node jar> -d cls CloseMidSnapshot.java
//   java -XX:ErrorFile=<dir>/hs_err_%p.log -cp <jar>:cls CloseMidSnapshot <case> <work dir>
// The order is forced with latches, not timing:
//   logic: read k once -> count down IN_LOGIC -> wait (at most WAIT_MS) for CLOSE_RETURNED -> [second read] -> return
//   closer thread: wait IN_LOGIC -> store.close() -> count down CLOSE_RETURNED
// Cases:
//   C0  control: no close during logic; logic reads k twice; then the main thread closes the store.
//   C1  close during logic, then a second read through the snapshot, then processSnapshot's release.
//   C2  close during logic, no second read: only the release follows the close.
//   C3  close during logic; once close has started (a snapshot read fails, or close returned), a second processSnapshot
//       on a third thread ("late"); the logic waits (at most WAIT_MS) for it to end, then returns. The first
//       processSnapshot runs on a "dump" thread that main joins for at most HANG_MS, so a hang is recorded (exit 3,
//       with each live thread's state and its innermost scorex.db frame), not waited out.
// Printed lines: JAR, JAVA, FACTORY, then STEP lines as each point is passed (flushed), then
//   CASE <id> result=<Success(v)|Failure(X: msg)|threw(X)> closeReturnedDuringLogic=<bool> secondRead=<...>
//   closerDone=<bool> closerError=<X|none>
// (C3: CASE C3 result=<...|pending> closeReturnedDuringLogic=<bool> closeSeen=<read-failed|close-returned|timeout>
//   late=<...> lateRan=<bool> lateHeldLock=<bool> dumpDone=<bool> closerDone=<bool> closerError=<X|none> hang=<bool>)
// and END. A line that is missing after a STEP is where the JVM stopped.
import scorex.db.LDBFactory;
import scorex.db.LDBVersionedStore;

import java.io.File;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

public class CloseMidSnapshot {
  static final long WAIT_MS = 3000;
  static final long HANG_MS = 10000;

  static void step(String s) { System.out.println("STEP " + s); System.out.flush(); }

  static scala.collection.TraversableOnce<scala.Tuple2<byte[], byte[]>> pairs(byte[] k, byte[] v) {
    List<scala.Tuple2<byte[], byte[]>> l = new ArrayList<>();
    l.add(new scala.Tuple2<>(k, v));
    return scala.collection.JavaConverters.asScalaBufferConverter(l).asScala();
  }

  static scala.collection.TraversableOnce<byte[]> none() {
    return scala.collection.JavaConverters.asScalaBufferConverter(new ArrayList<byte[]>()).asScala();
  }

  static String describe(Throwable t) {
    if (t == null) return "none";
    String m = t.getMessage();
    return t.getClass().getSimpleName() + (m == null ? "" : ": " + m.replace('\n', ' '));
  }

  static String innermost(Thread t) {
    for (StackTraceElement e : t.getStackTrace())
      if (e.getClassName().startsWith("scorex.db.")) return e.getClassName() + "." + e.getMethodName();
    return "-";
  }

  // C3: a second processSnapshot that starts after close() has started, while the first one still holds its snapshot.
  static void lateCall(final LDBVersionedStore store, final byte[] k) throws Exception {
    final CountDownLatch inLogic = new CountDownLatch(1);
    final CountDownLatch closeReturned = new CountDownLatch(1);
    final CountDownLatch lateDone = new CountDownLatch(1);
    final AtomicReference<Throwable> closerError = new AtomicReference<>();
    final AtomicReference<String> dumpResult = new AtomicReference<>("pending");
    final AtomicReference<String> late = new AtomicReference<>("not-run");
    final AtomicReference<String> closeSeen = new AtomicReference<>("timeout");
    final boolean[] lateRan = {false};
    final boolean[] lateHeldLock = {false};
    final boolean[] closeReturnedDuringLogic = {false};

    Thread closer = new Thread(() -> {
      try {
        inLogic.await();
        step("closer: calling store.close()");
        store.close();
        step("closer: store.close() returned");
      } catch (Throwable t) {
        closerError.set(t);
        step("closer: store.close() threw " + describe(t));
      } finally {
        closeReturned.countDown();
      }
    }, "closer");

    Thread lateThread = new Thread(() -> {
      step("late: calling processSnapshot");
      try {
        scala.util.Try<Object> t = store.processSnapshot(r -> { lateRan[0] = true; return 7; });
        late.set(t.isSuccess() ? "Success(" + t.get() + ")" : "Failure(" + describe(t.failed().get()) + ")");
      } catch (Throwable t) {
        late.set("threw(" + describe(t) + ")");
      }
      lateHeldLock[0] = store.lock().isWriteLockedByCurrentThread();
      step("late: processSnapshot ended: " + late.get() + " heldLock=" + lateHeldLock[0]);
      lateDone.countDown();
    }, "late");

    scala.Function1<LDBVersionedStore.SnapshotReadInterface, Object> logic = r -> {
      byte[] v1 = r.get(k);
      step("logic: first read " + (v1 == null ? "null" : v1.length + " bytes"));
      inLogic.countDown();
      // close has started once a read through the snapshot fails or close() has returned
      long deadline = System.currentTimeMillis() + WAIT_MS;
      while (System.currentTimeMillis() < deadline) {
        if (closeReturned.getCount() == 0) { closeSeen.set("close-returned"); break; }
        try { r.get(k); } catch (Throwable t) { closeSeen.set("read-failed"); break; }
        try { Thread.sleep(5); } catch (InterruptedException e) { throw new RuntimeException(e); }
      }
      closeReturnedDuringLogic[0] = closeReturned.getCount() == 0;
      step("logic: close seen = " + closeSeen.get() + "; starting late");
      lateThread.start();
      boolean ended;
      try { ended = lateDone.await(WAIT_MS, TimeUnit.MILLISECONDS); } catch (InterruptedException e) { throw new RuntimeException(e); }
      step("logic: late ended = " + ended + "; returning; processSnapshot releases its snapshot next");
      return 42;
    };

    Thread dump = new Thread(() -> {
      try {
        scala.util.Try<Object> t = store.processSnapshot(logic);
        dumpResult.set(t.isSuccess() ? "Success(" + t.get() + ")" : "Failure(" + describe(t.failed().get()) + ")");
      } catch (Throwable t) {
        dumpResult.set("threw(" + describe(t) + ")");
      }
      step("dump: processSnapshot returned (snapshot released)");
    }, "dump");

    closer.start();
    dump.start();
    dump.join(HANG_MS);
    closer.join(dump.isAlive() ? 1000 : HANG_MS);
    lateThread.join(1000);
    boolean hang = dump.isAlive() || closer.isAlive() || lateThread.isAlive();
    for (Thread t : new Thread[]{dump, closer, lateThread})
      if (t.isAlive()) step("main: after " + HANG_MS + " ms still alive: " + t.getName() + " " + t.getState() + " in " + innermost(t));
    if (hang) step("main: write lock " + (store.lock().isWriteLocked() ? "held" : "free"));
    System.out.println("CASE C3 result=" + dumpResult.get() + " closeReturnedDuringLogic=" + closeReturnedDuringLogic[0]
        + " closeSeen=" + closeSeen.get() + " late=" + late.get() + " lateRan=" + lateRan[0]
        + " lateHeldLock=" + lateHeldLock[0] + " dumpDone=" + !dump.isAlive() + " closerDone=" + !closer.isAlive()
        + " closerError=" + describe(closerError.get()) + " hang=" + hang);
    System.out.println("END");
    System.out.flush();
    System.exit(hang ? 3 : 0);
  }

  public static void main(String[] args) throws Exception {
    final String id = args[0];
    File work = new File(args[1]);
    work.mkdirs();
    System.out.println("JAR " + LDBVersionedStore.class.getProtectionDomain().getCodeSource().getLocation());
    System.out.println("JAVA " + System.getProperty("java.version") + " " + System.getProperty("java.vm.name"));
    System.out.println("FACTORY " + LDBFactory.factory());

    File storeDir = new File(work, "store-" + id);
    storeDir.mkdirs();
    final LDBVersionedStore store = new LDBVersionedStore(storeDir, 2);
    final byte[] k = {9};
    store.update(new byte[]{1}, none(), pairs(k, new byte[]{1, 2, 3})).get();

    if (id.equals("C3")) { lateCall(store, k); return; }

    final boolean closeDuring = !id.equals("C0");
    final boolean secondRead = !id.equals("C2");
    final CountDownLatch inLogic = new CountDownLatch(1);
    final CountDownLatch closeReturned = new CountDownLatch(1);
    final AtomicReference<Throwable> closerError = new AtomicReference<>();
    final StringBuilder second = new StringBuilder("not-done");
    final boolean[] closeReturnedDuringLogic = {false};

    Thread closer = new Thread(() -> {
      try {
        inLogic.await();
        step("closer: calling store.close()");
        store.close();
        step("closer: store.close() returned");
      } catch (Throwable t) {
        closerError.set(t);
        step("closer: store.close() threw " + describe(t));
      } finally {
        closeReturned.countDown();
      }
    }, "closer");
    if (closeDuring) closer.start();

    scala.Function1<LDBVersionedStore.SnapshotReadInterface, Object> logic = r -> {
      byte[] v1 = r.get(k);
      step("logic: first read " + (v1 == null ? "null" : v1.length + " bytes"));
      inLogic.countDown();
      if (closeDuring) {
        try {
          closeReturnedDuringLogic[0] = closeReturned.await(WAIT_MS, TimeUnit.MILLISECONDS);
        } catch (InterruptedException e) { throw new RuntimeException(e); }
        step("logic: close returned during logic = " + closeReturnedDuringLogic[0]);
      }
      if (secondRead) {
        second.setLength(0);
        try {
          byte[] v2 = r.get(k);
          second.append("value(").append(v2 == null ? "null" : v2.length + " bytes").append(")");
        } catch (Throwable t) {
          second.append("threw(").append(describe(t)).append(")");
        }
        step("logic: second read " + second);
      } else {
        second.setLength(0); second.append("skipped");
      }
      step("logic: returning; processSnapshot releases its snapshot next");
      return 42;
    };

    String result;
    try {
      scala.util.Try<Object> t = store.processSnapshot(logic);
      result = t.isSuccess() ? "Success(" + t.get() + ")" : "Failure(" + describe(t.failed().get()) + ")";
    } catch (Throwable t) {
      result = "threw(" + describe(t) + ")";
    }
    step("main: processSnapshot returned (snapshot released)");
    boolean closerDone = true;
    if (closeDuring) {
      closer.join(10000);
      closerDone = !closer.isAlive();
    } else {
      store.close();
      step("main: store.close() returned");
    }
    System.out.println("CASE " + id + " result=" + result + " closeReturnedDuringLogic=" + closeReturnedDuringLogic[0]
        + " secondRead=" + second + " closerDone=" + closerDone + " closerError=" + describe(closerError.get()));
    System.out.println("END");
    System.out.flush();
    System.exit(0);
  }
}
