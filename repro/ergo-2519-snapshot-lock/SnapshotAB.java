// Drives LDBVersionedStore.processSnapshot of one node jar directly, through the store's own LevelDB factory, and
// prints one normalized line per case. Run it once per jar, with that jar on the class path:
//   javac -cp <any node jar> -d cls SnapshotAB.java
//   java -cp <jar>:cls SnapshotAB <work dir>
// With the node jar on the system class path, scorex.db.LDBFactory loads the native LevelDB (leveldbjni), as a node
// started with `java -jar` does; the FACTORY line shows which one was loaded.
//
// Cases (each on a fresh store in its own directory under <work dir>):
//   PC  control: this thread holds the store's write lock; another thread's tryLock must report "blocked".
//   R1  a snapshot taken after the store was closed (the native factory refuses one with DBException "Closed").
//   I1  injected: the DB's getSnapshot throws DBException on an open store; another thread then runs store.update.
//   I2  injected: processing throws IllegalStateException.
//   I3  injected: processing returns 42, Snapshot.close throws IOException.
//   I4  injected: processing throws IllegalStateException, Snapshot.close throws IOException.
//   I5  injected: processing throws InterruptedException.
//   I6  injected: processing throws scala.runtime.NonLocalReturnControl (a ControlThrowable).
//   I7  injected: processing returns 42, Snapshot.close throws InterruptedException.
//   N1  no injection: write k=v1, then inside processing read k, write k=v2 with store.update, read k again.
// Injection replaces the store's `db` field, after the store opened, with a java.lang.reflect.Proxy over the real DB;
// getSnapshot hands out a wrapper whose close() closes the real snapshot first, and reads through the wrapper are
// served from the real snapshot. Nothing else in the store is touched.
import org.iq80.leveldb.DB;
import org.iq80.leveldb.DBException;
import org.iq80.leveldb.ReadOptions;
import org.iq80.leveldb.Snapshot;
import scorex.db.LDBFactory;
import scorex.db.LDBVersionedStore;

import java.io.File;
import java.io.IOException;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

public class SnapshotAB {

  static File work;
  static int dirs = 0;

  @SuppressWarnings("unchecked")
  static <E extends Throwable> RuntimeException sneaky(Throwable t) throws E { throw (E) t; }

  static class Calls {
    Throwable acquisitionFailure, closeFailure;
    int acquisitions, closes, logic;
    boolean lockHeldAtAcquisition;
  }

  static final class ExposedSnapshot implements Snapshot {
    final Snapshot real; final Calls calls;
    ExposedSnapshot(Snapshot real, Calls calls) { this.real = real; this.calls = calls; }
    @Override public void close() throws IOException {
      calls.closes++;
      real.close();
      if (calls.closeFailure != null) throw sneaky(calls.closeFailure);
    }
  }

  static LDBVersionedStore newStore() {
    File d = new File(work, "store-" + (dirs++));
    d.mkdirs();
    return new LDBVersionedStore(d, 2);
  }

  static void inject(final LDBVersionedStore store, final Calls calls) throws Exception {
    final DB original = store.db();
    InvocationHandler h = new InvocationHandler() {
      ExposedSnapshot exposed;
      @Override public Object invoke(Object proxy, Method m, Object[] args) throws Throwable {
        if (m.getName().equals("getSnapshot") && (args == null || args.length == 0)) {
          calls.lockHeldAtAcquisition = store.lock().isWriteLockedByCurrentThread();
          calls.acquisitions++;
          if (calls.acquisitionFailure != null) throw calls.acquisitionFailure;
          exposed = new ExposedSnapshot(original.getSnapshot(), calls);
          return exposed;
        }
        if (m.getName().equals("get") && args != null && args.length == 2 && args[1] instanceof ReadOptions) {
          ReadOptions o = (ReadOptions) args[1];
          if (exposed != null && o.snapshot() == exposed) {
            return original.get((byte[]) args[0], new ReadOptions().snapshot(exposed.real));
          }
        }
        try {
          return m.invoke(original, args);
        } catch (InvocationTargetException e) {
          throw e.getCause();
        }
      }
    };
    DB proxy = (DB) Proxy.newProxyInstance(DB.class.getClassLoader(), new Class<?>[]{DB.class}, h);
    Field f = LDBVersionedStore.class.getDeclaredField("db");
    f.setAccessible(true);
    f.set(store, proxy);
  }

  /** Can another thread take the write lock within 1.5 s? */
  static String otherThread(final LDBVersionedStore store) throws Exception {
    final AtomicBoolean got = new AtomicBoolean(false);
    Thread t = new Thread(() -> {
      try {
        if (store.lock().writeLock().tryLock(1500, TimeUnit.MILLISECONDS)) {
          got.set(true);
          store.lock().writeLock().unlock();
        }
      } catch (InterruptedException ignored) { }
    });
    t.start(); t.join();
    return got.get() ? "free" : "blocked";
  }

  static scala.collection.TraversableOnce<scala.Tuple2<byte[], byte[]>> pairs(byte[] k, byte[] v) {
    List<scala.Tuple2<byte[], byte[]>> l = new ArrayList<>();
    l.add(new scala.Tuple2<>(k, v));
    return scala.collection.JavaConverters.asScalaBufferConverter(l).asScala();
  }

  static scala.collection.TraversableOnce<byte[]> none() {
    return scala.collection.JavaConverters.asScalaBufferConverter(new ArrayList<byte[]>()).asScala();
  }

  static String name(Throwable t) { return t == null ? "none" : t.getClass().getSimpleName(); }

  /** Calls processSnapshot and returns "Success(v)", "Failure(X)" or "threw(X)", plus identity against `injected`. */
  static String call(LDBVersionedStore store, scala.Function1<LDBVersionedStore.SnapshotReadInterface, Object> logic,
                     Throwable injected, StringBuilder extra) {
    try {
      scala.util.Try<Object> r = store.processSnapshot(logic);
      if (r.isSuccess()) return "Success(" + r.get() + ")";
      Throwable e = r.failed().get();
      describe(e, injected, extra);
      return "Failure(" + name(e) + ")";
    } catch (Throwable e) {
      describe(e, injected, extra);
      return "threw(" + name(e) + ")";
    } finally {
      Thread.interrupted(); // clear any interrupt status a case left behind
    }
  }

  static void describe(Throwable e, Throwable injected, StringBuilder extra) {
    if (injected != null) extra.append(" same=").append(e == injected);
    Throwable[] s = e.getSuppressed();
    StringBuilder sb = new StringBuilder();
    for (Throwable x : s) sb.append(sb.length() == 0 ? "" : ",").append(name(x));
    extra.append(" suppressed=[").append(sb).append("]");
  }

  static void release(LDBVersionedStore store) {
    while (store.lock().isWriteLockedByCurrentThread()) store.lock().writeLock().unlock();
  }

  static void print(String id, String result, Calls c, LDBVersionedStore store, String other, StringBuilder extra) {
    StringBuilder sb = new StringBuilder("CASE ").append(id).append(" result=").append(result);
    if (c != null) {
      sb.append(" logic=").append(c.logic).append(" acq=").append(c.acquisitions).append(" closes=").append(c.closes)
        .append(" lockAtAcq=").append(c.lockHeldAtAcquisition);
    }
    sb.append(" heldAfter=").append(store.lock().isWriteLockedByCurrentThread());
    sb.append(" other=").append(other);
    if (extra != null) sb.append(extra);
    System.out.println(sb);
  }

  interface Body { Object run(LDBVersionedStore.SnapshotReadInterface r) throws Throwable; }

  static scala.Function1<LDBVersionedStore.SnapshotReadInterface, Object> fn(final Calls c, final Body b) {
    return r -> {
      if (c != null) c.logic++;
      try { return b.run(r); } catch (Throwable t) { throw sneaky(t); }
    };
  }

  /** One injected case: configure failures, call, print. */
  static void injected(String id, Throwable acq, Throwable close, final Throwable thrownByLogic, Throwable identity)
      throws Exception {
    LDBVersionedStore store = newStore();
    Calls c = new Calls();
    inject(store, c);
    c.acquisitionFailure = acq; c.closeFailure = close;
    StringBuilder extra = new StringBuilder();
    String result = call(store, fn(c, r -> { if (thrownByLogic != null) throw thrownByLogic; return 42; }), identity, extra);
    String other = otherThread(store);
    print(id, result, c, store, other, extra);
    release(store);
    store.close();
  }

  public static void main(String[] args) throws Exception {
    work = new File(args[0]);
    work.mkdirs();
    System.out.println("JAR " + LDBVersionedStore.class.getProtectionDomain().getCodeSource().getLocation());
    System.out.println("JAVA " + System.getProperty("java.version") + " " + System.getProperty("java.vm.name"));
    System.out.println("FACTORY " + LDBFactory.factory());

    // PC: the cross-thread probe must see a lock this thread holds
    {
      LDBVersionedStore store = newStore();
      store.lock().writeLock().lock();
      String other = otherThread(store);
      System.out.println("CASE PC heldAfter=" + store.lock().isWriteLockedByCurrentThread() + " other=" + other);
      release(store);
      store.close();
    }

    // R1: snapshot of a closed store, no injection
    {
      LDBVersionedStore store = newStore();
      store.update(new byte[]{1}, none(), pairs(new byte[]{9}, new byte[]{1})).get();
      store.close();
      Calls c = new Calls();
      StringBuilder extra = new StringBuilder();
      String result = call(store, fn(c, r -> r.get(new byte[]{9}).length), null, extra);
      String other = otherThread(store);
      System.out.println("CASE R1 result=" + result + " logic=" + c.logic + " heldAfter="
          + store.lock().isWriteLockedByCurrentThread() + " other=" + other + extra);
      release(store);
    }

    // I1: acquisition fails on an open store; then a writer on another thread
    {
      LDBVersionedStore store = newStore();
      Calls c = new Calls();
      inject(store, c);
      DBException failure = new DBException("injected acquisition failure");
      c.acquisitionFailure = failure;
      StringBuilder extra = new StringBuilder();
      String result = call(store, fn(c, r -> 42), failure, extra);
      String other = otherThread(store);
      final LDBVersionedStore s = store;
      final AtomicBoolean done = new AtomicBoolean(false);
      Thread writer = new Thread(() -> {
        s.update(new byte[]{2}, none(), pairs(new byte[]{7}, new byte[]{7}));
        done.set(true);
      });
      writer.start();
      writer.join(3000);
      String w = done.get() ? "done" : "blocked";
      extra.append(" writer=").append(w);
      print("I1", result, c, store, other, extra);
      release(store);
      writer.join(10000);
      System.out.println("CASE I1-after-release writer=" + (done.get() ? "done" : "blocked"));
      store.close();
    }

    IllegalStateException ise = new IllegalStateException("processing failed");
    injected("I2", null, null, ise, ise);
    IOException ioe = new IOException("snapshot close failed");
    injected("I3", null, ioe, null, ioe);
    IllegalStateException ise4 = new IllegalStateException("processing failed");
    IOException ioe4 = new IOException("snapshot close failed");
    injected("I4", null, ioe4, ise4, ise4);
    InterruptedException ie = new InterruptedException("processing interrupted");
    injected("I5", null, null, ie, ie);
    scala.runtime.NonLocalReturnControl<Object> nlr = new scala.runtime.NonLocalReturnControl<Object>(new Object(), 1);
    injected("I6", null, null, nlr, nlr);
    InterruptedException ie7 = new InterruptedException("close interrupted");
    injected("I7", null, ie7, null, ie7);

    // N1: a stable view across a write made during processing, no injection
    {
      final LDBVersionedStore store = newStore();
      final byte[] k = {5};
      store.update(new byte[]{1}, none(), pairs(k, new byte[]{1})).get();
      Calls c = new Calls();
      StringBuilder extra = new StringBuilder();
      String result = call(store, fn(c, r -> {
        byte b1 = r.get(k)[0];
        store.update(new byte[]{2}, none(), pairs(k, new byte[]{2})).get();
        byte b2 = r.get(k)[0];
        return b1 + "/" + b2;
      }), null, extra);
      String after = Arrays.toString((byte[]) store.get(k).get());
      String other = otherThread(store);
      System.out.println("CASE N1 result=" + result + " logic=" + c.logic + " storeAfter=" + after
          + " heldAfter=" + store.lock().isWriteLockedByCurrentThread() + " other=" + other);
      release(store);
      store.close();
    }
    System.out.println("END");
    System.exit(0);
  }
}
