// ModifiersAB: feeds the same Modifiers message payloads to org.ergoplatform.network.message.ModifiersSpec.parse
// of one node jar (the jar on the class path), and prints one CASE line per input: what parse returned
// (the parsed entry count, or the exception class and message), where the reader stood when parse returned or
// threw, and the input's size and sha256 prefix (the same inputs on every jar).
// It also passes some of the payloads to the node's own message handler entry point,
// scorex.core.network.Synchronizer.parseAndHandle, with a handler and a penalty hook that only count calls
// (SYNC lines), and checks that the reference test vector from the node's ModifiersSpecification and two
// serializer-written messages survive a parse/serialize round trip (RT lines).
// Inputs are built by this file's own encoder (minimal VLQ, as the node writes), not by the jar under test, except
// where a line says "written by the jar's serializer".
// Used for ergoplatform/ergo#2942 and #2958 (issue #2918). Compile against any of the jars; run once per jar:
//   javac -cp <jar> -d cls ModifiersAB.java && java -Xmx2g -cp <jar>:cls ModifiersAB
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.security.MessageDigest;

import org.ergoplatform.network.message.MessageSpec;
import org.ergoplatform.network.message.ModifiersData;
import org.ergoplatform.network.message.ModifiersSpec$;
import scorex.core.network.ConnectedPeer;
import scorex.core.network.Synchronizer;
import scorex.util.serialization.VLQByteBufferReader;

public class ModifiersAB {
    static final ModifiersSpec$ SPEC = ModifiersSpec$.MODULE$;
    static final byte TX = 2, HEADER = 101, PROOFS = 104;

    // ---- this file's own encoder ----
    static final class Enc {
        final ByteArrayOutputStream b = new ByteArrayOutputStream();
        Enc put(int x) { b.write(x); return this; }
        Enc vlq(long v) { // unsigned LEB128, minimal, as scorex VLQWriter.putULong writes it
            while ((v & ~0x7FL) != 0) { b.write((int) ((v & 0x7F) | 0x80)); v >>>= 7; }
            b.write((int) v); return this;
        }
        Enc bytes(byte[] x) { b.write(x, 0, x.length); return this; }
        byte[] get() { return b.toByteArray(); }
    }
    static byte[] id(int i) { return ByteBuffer.allocate(32).putInt(i).array(); } // distinct for distinct i
    // declared count, then `entries` entries: id(i) (or id(0) for every entry when dup), body length, body
    static byte[] msg(byte type, long declared, int entries, int bodyLen, boolean dup) {
        Enc e = new Enc().put(type).vlq(declared);
        byte[] body = new byte[bodyLen];
        for (int i = 0; i < entries; i++) e.bytes(id(dup ? 0 : i)).vlq(bodyLen).bytes(body);
        return e.get();
    }

    static String hex8(byte[] x) throws Exception {
        byte[] d = MessageDigest.getInstance("SHA-256").digest(x);
        StringBuilder s = new StringBuilder();
        for (int i = 0; i < 4; i++) s.append(String.format("%02x", d[i]));
        return s.toString();
    }
    static String fail(Throwable t) {
        return "Failure(" + t.getClass().getSimpleName() + ": " + t.getMessage() + ")";
    }

    // parse exactly as the node's handler does (parseBytesTry), and again on a reader of our own to see its position
    static void parseCase(String name, byte[] in) throws Exception {
        String res;
        scala.util.Try<ModifiersData> t = SPEC.parseBytesTry(in);
        if (t.isSuccess()) res = "Success(n=" + t.get().modifiers().size() + ")";
        else res = fail(((scala.util.Failure<?>) t).exception());
        VLQByteBufferReader r = new VLQByteBufferReader(ByteBuffer.wrap(in));
        String direct;
        try { direct = "Success(n=" + SPEC.parse(r).modifiers().size() + ")"; } catch (Throwable x) { direct = fail(x); }
        if (!direct.equals(res)) res = res + " MISMATCH-direct=" + direct;
        System.out.println("CASE " + name + " result=" + res + " pos=" + r.position()
                + " bytes=" + in.length + " in=" + hex8(in));
    }

    // ---- the node's message entry point, with counting hooks ----
    static final class Probe implements Synchronizer {
        private com.typesafe.scalalogging.Logger logger;
        int penalized = 0;
        Probe() {
            com.typesafe.scalalogging.StrictLogging.$init$(this);
            scorex.util.ScorexLogging.$init$(this);
            Synchronizer.$init$(this);
        }
        public com.typesafe.scalalogging.Logger logger() { return logger; }
        public void com$typesafe$scalalogging$StrictLogging$_setter_$logger_$eq(com.typesafe.scalalogging.Logger l) { logger = l; }
        public void penalizeMaliciousPeer(ConnectedPeer peer) { penalized++; }
    }
    static final class Handler extends scala.runtime.AbstractPartialFunction<scala.Tuple3<MessageSpec<?>, ?, ConnectedPeer>, scala.runtime.BoxedUnit> {
        int calls = 0; int lastN = -1;
        public boolean isDefinedAt(scala.Tuple3<MessageSpec<?>, ?, ConnectedPeer> x) { return x._2() instanceof ModifiersData; }
        @SuppressWarnings("unchecked")
        public <A1 extends scala.Tuple3<MessageSpec<?>, ?, ConnectedPeer>, B1> B1 applyOrElse(A1 x, scala.Function1<A1, B1> dflt) {
            if (!isDefinedAt(x)) return dflt.apply(x);
            calls++; lastN = ((ModifiersData) x._2()).modifiers().size();
            return (B1) scala.runtime.BoxedUnit.UNIT;
        }
    }
    @SuppressWarnings("unchecked")
    static void syncCase(String name, byte[] in) {
        Probe p = new Probe(); Handler h = new Handler();
        scala.util.Try<scala.runtime.BoxedUnit> t = p.parseAndHandle(h, (MessageSpec<Object>) (Object) SPEC, in, null);
        String res = t.isSuccess() ? "Success" : "Failure(" + ((scala.util.Failure<?>) t).exception().getClass().getSimpleName() + ")";
        System.out.println("SYNC " + name + " result=" + res + " handlerCalls=" + h.calls
                + " handlerEntries=" + (h.calls > 0 ? h.lastN : "-") + " penalizeMaliciousPeer=" + p.penalized);
    }

    // ---- round trips ----
    static scala.collection.immutable.Map<String, byte[]> entries(int n, boolean varying) {
        scala.collection.immutable.Map<String, byte[]> m = scala.collection.immutable.Map$.MODULE$.empty();
        for (int i = 0; i < n; i++) {
            byte[] body = new byte[varying ? (i % 50) : 0];
            for (int k = 0; k < body.length; k++) body[k] = (byte) (i + k);
            m = m.$plus(new scala.Tuple2<String, byte[]>(scorex.util.encode.Base16$.MODULE$.encode(id(i)), body));
        }
        return m;
    }
    static boolean sameMap(scala.collection.immutable.Map<String, byte[]> a, scala.collection.immutable.Map<String, byte[]> b) {
        if (a.size() != b.size()) return false;
        scala.collection.Iterator<scala.Tuple2<String, byte[]>> it = a.iterator();
        while (it.hasNext()) {
            scala.Tuple2<String, byte[]> e = it.next();
            scala.Option<byte[]> o = b.get(e._1());
            if (o.isEmpty() || !java.util.Arrays.equals(o.get(), e._2())) return false;
        }
        return true;
    }
    static void rtCase(String name, byte type, int n) throws Exception {
        ModifiersData d = new ModifiersData(type, entries(n, true));
        byte[] w = SPEC.toBytes(d); // written by the jar's serializer
        scala.util.Try<ModifiersData> t = SPEC.parseBytesTry(w);
        String res = t.isSuccess() ? ("Success(n=" + t.get().modifiers().size() + ") same=" + sameMap(d.modifiers(), t.get().modifiers())
                + " type=" + (t.get().typeId() == type))
                : fail(((scala.util.Failure<?>) t).exception());
        System.out.println("RT " + name + " written=" + n + " entries by the jar's serializer, bytes=" + w.length + " parse=" + res);
    }
    // the reference vector of ModifiersSpecification ("modifiers message reference parser"): a framed message
    // (magic 4, code 1, length 4, checksum 4, then the payload); parse the payload and write it back
    static final String REF = "0100020421000001058fdd57ca65010d537f94ae67e5026fd4acee1cdd1e7281a73e94a7681864438c629e9683b3a5e1014201ad7fffba807080ce7f808001b4771880bdffbd7fff857f8db17fdc89b0015bff0189486d80934a84015e03c064c6d100c17fae55bf01f380007fbb00ff01d9000000013f0680d10015ff11c4b7ffff01ffb2d27f0001050064010080ffb93e7fff4cc15a2bffdd770480007f8080ff8026802f7f51007f004b01ff0080002380a581e8c0ca81dfca62007fa7ff01860019f37f3c4491067cd1001ee07e570fe8689b80ff11017aff7408703927a2bbc4fa0200000000032bdb4c610ddf0078b4f31f5a36bff7b003704dfc93b201fedd8fe331d9ff1102008d7fff010d80ff";
    static void refCase() throws Exception {
        byte[] framed = new byte[REF.length() / 2];
        for (int i = 0; i < framed.length; i++) framed[i] = (byte) Integer.parseInt(REF.substring(2 * i, 2 * i + 2), 16);
        byte[] payload = java.util.Arrays.copyOfRange(framed, 13, framed.length);
        scala.util.Try<ModifiersData> t = SPEC.parseBytesTry(payload);
        String res;
        if (t.isSuccess()) {
            byte[] back = SPEC.toBytes(t.get());
            res = "Success(n=" + t.get().modifiers().size() + ") type=" + t.get().typeId() + " rewritten=" + (java.util.Arrays.equals(back, payload) ? "same-bytes" : "different");
        } else res = fail(((scala.util.Failure<?>) t).exception());
        System.out.println("RT REF payload=" + payload.length + " bytes of the reference vector, parse=" + res);
    }

    static String classSha(String res) throws Exception {
        InputStream in = ModifiersAB.class.getClassLoader().getResourceAsStream(res);
        if (in == null) return "absent";
        ByteArrayOutputStream b = new ByteArrayOutputStream(); byte[] buf = new byte[8192]; int k;
        while ((k = in.read(buf)) > 0) b.write(buf, 0, k);
        return hex8(b.toByteArray());
    }

    public static void main(String[] a) throws Exception {
        System.out.println("JAR " + SPEC.getClass().getProtectionDomain().getCodeSource().getLocation().getPath()
                .replaceAll(".*/", ""));
        System.out.println("JAVA " + System.getProperty("java.version") + " " + System.getProperty("java.vm.name"));
        System.out.println("CLASS ModifiersSpec$ sha256[0:8]=" + classSha("org/ergoplatform/network/message/ModifiersSpec$.class")
                + " InvSpec.maxInvObjects=" + org.ergoplatform.network.message.InvSpec$.MODULE$.maxInvObjects()
                + " maxMsgSizeWithReserve=" + SPEC.maxMsgSizeWithReserve());
        int budget = SPEC.maxMsgSizeWithReserve();
        int maxEmpty = (budget - 5) / 32; // empty entries the byte budget admits: 5 + 32*n <= budget
        // counts around the cap, distinct ids, empty bodies, transaction type
        parseCase("Z0", msg(TX, 0, 0, 0, false));
        parseCase("N1", msg(TX, 1, 1, 0, false));
        parseCase("N399", msg(TX, 399, 399, 0, false));
        parseCase("N400", msg(TX, 400, 400, 0, false));
        parseCase("N401", msg(TX, 401, 401, 0, false));
        parseCase("N401-proofs", msg(PROOFS, 401, 401, 0, false));
        // declared count against distinct ids: every entry carries the same id
        parseCase("D400-same-id", msg(TX, 400, 400, 0, true));
        parseCase("D401-same-id", msg(TX, 401, 401, 0, true));
        // the issue's case: as many empty entries as the byte budget admits, and one more
        parseCase("ISSUE-" + maxEmpty, msg(TX, maxEmpty, maxEmpty, 0, false));
        parseCase("BUDGET-" + (maxEmpty + 1), msg(TX, maxEmpty + 1, maxEmpty + 1, 0, false));
        // declared counts with no entries behind them
        parseCase("HUGE-2147483647-no-entries", msg(TX, 2147483647L, 0, 0, false));
        parseCase("OVERINT-2147483648-no-entries", msg(TX, 2147483648L, 0, 0, false));
        // malformed lengths
        parseCase("TRUNC-400-declared-399-present", msg(TX, 400, 399, 0, false));
        byte[] shortBody = new Enc().put(TX).vlq(1).bytes(id(1)).vlq(1000).bytes(new byte[10]).get();
        parseCase("LEN-1000-declared-10-present", shortBody);
        // large bodies: 400 entries at the byte budget, and one byte per entry over it
        int fit = (budget - 5) / 400 - 32; // 5 + 400*(32+fit) <= budget
        parseCase("BIG400-" + fit, msg(TX, 400, 400, fit, false));
        parseCase("BIG400-" + (fit + 1), msg(TX, 400, 400, fit + 1, false));
        // round trips
        refCase();
        rtCase("RT400", HEADER, 400);
        rtCase("RT401", HEADER, 401);
        // the node's handler entry point
        syncCase("Z0", msg(TX, 0, 0, 0, false));
        syncCase("N400", msg(TX, 400, 400, 0, false));
        syncCase("N401", msg(TX, 401, 401, 0, false));
        syncCase("ISSUE-" + maxEmpty, msg(TX, maxEmpty, maxEmpty, 0, false));
        syncCase("HUGE-2147483647-no-entries", msg(TX, 2147483647L, 0, 0, false));
        System.out.println("END");
    }
}
