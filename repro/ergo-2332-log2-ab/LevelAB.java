// #2332 A/B: the base jar's NipopowAlgos.log2 against the candidate jar's, in one JVM, each jar in its own
// classloader, over level-boundary rows (as in issue #2556), 1,000,000 seeded random pairs and the PR's three canary pairs.
// Java 8 source, no dependencies beyond the two jars.
//
//   java LevelAB <base.jar> <candidate.jar>
//
// Per row the level is (log2(T) - log2(h)).toInt, as NipopowAlgos.maxLevelOf computes it:
//   base:      log2(Double) applied to BigInt.doubleValue (the base jar's own method and its own BigInt)
//   candidate: log2(BigInt) (the candidate jar's own method and its own BigInt)
//   control:   StrictMath.log in this harness; it must differ from base on some x86_64 boundary row (class C of issue #2556).
// Exit 0 and "VERDICT SAME" when no row differs between base and candidate (level or bits) and the controls hold.
import java.io.File;
import java.lang.reflect.*;
import java.math.BigInteger;
import java.net.URL;
import java.net.URLClassLoader;
import java.util.*;

public class LevelAB {
  static final BigInteger Q = new BigInteger("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141", 16);
  static final String OBJ = "org.ergoplatform.modifiers.history.popow.NipopowAlgos$";

  static final class Arm {
    final String name; final Object module; final Method log2; final boolean bigArg;
    final Method bigApply; final Object bigModule; final Method doubleValue; final String source;
    Arm(String name, String jar) throws Exception {
      this.name = name;
      ClassLoader cl = new URLClassLoader(new URL[]{new File(jar).toURI().toURL()}, null);
      Class<?> c = Class.forName(OBJ, true, cl);
      module = c.getField("MODULE$").get(null);
      Class<?> bigC = Class.forName("scala.math.BigInt", true, cl);
      Method found = null; boolean big = false;
      for (Method m : c.getDeclaredMethods()) {
        if (!(m.getName().equals("log2") || m.getName().endsWith("$$log2"))) continue;
        Class<?>[] p = m.getParameterTypes();
        if (p.length == 1 && p[0] == double.class && found == null) { found = m; big = false; }
        if (p.length == 1 && p[0] == bigC) { found = m; big = true; }
      }
      if (found == null) throw new IllegalStateException(name + ": no log2 in " + OBJ);
      found.setAccessible(true);
      log2 = found; bigArg = big;
      Class<?> bigObj = Class.forName("scala.math.BigInt$", true, cl);
      bigModule = bigObj.getField("MODULE$").get(null);
      bigApply = bigObj.getMethod("apply", BigInteger.class);
      doubleValue = bigC.getMethod("doubleValue");
      source = c.getProtectionDomain().getCodeSource().getLocation() + " :: " + found.toGenericString();
    }
    // log2 of x exactly as maxLevelOf feeds it in this arm
    double lg(BigInteger x) throws Exception {
      Object b = bigApply.invoke(bigModule, x);
      if (bigArg) return (Double) log2.invoke(module, b);
      return (Double) log2.invoke(module, (Double) doubleValue.invoke(b));
    }
    Double ln2() {
      try { Field f = module.getClass().getDeclaredField("Ln2"); f.setAccessible(true); return (Double) f.get(module); }
      catch (Exception e) { return null; }
    }
  }

  static BigInteger decodeCompact(long nBits) {
    int size = (int) (nBits >> 24) & 0xFF;
    BigInteger m = BigInteger.valueOf(nBits & 0x007FFFFFL);
    return size <= 3 ? m.shiftRight(8 * (3 - size)) : m.shiftLeft(8 * (size - 3));
  }

  static double ctlLog2(BigInteger x) { return StrictMath.log(x.doubleValue()) / StrictMath.log(2); }

  // Replicas of the candidate's log2 with a different shift threshold. Not the jar.
  static final int[] TH = {64, 128, 255, 256, 977};
  static final long[] thLevel = new long[TH.length], thBits = new long[TH.length];
  static final double LN2 = Math.log(2);
  static double repLog2(BigInteger x, int th) {
    int blex = x.bitLength() - th;
    return blex > 0 ? Math.log(x.shiftRight(blex).doubleValue()) / LN2 + blex : Math.log(x.doubleValue()) / LN2;
  }

  static long rows, levelDiff, bitDiff, ctlDiff;
  static String firstLevelDiff = "-", firstBitDiff = "-";

  static void row(Arm a, Arm b, BigInteger t, BigInteger h, String tag) throws Exception {
    double at = a.lg(t), ah = a.lg(h), bt = b.lg(t), bh = b.lg(h);
    int la = (int) (at - ah), lb = (int) (bt - bh);
    int lc = (int) (ctlLog2(t) - ctlLog2(h));
    rows++;
    if (la != lb) { levelDiff++; if (firstLevelDiff.equals("-")) firstLevelDiff = tag + " T=" + t + " h=" + h + " base=" + la + " cand=" + lb; }
    if (Double.doubleToRawLongBits(at) != Double.doubleToRawLongBits(bt) || Double.doubleToRawLongBits(ah) != Double.doubleToRawLongBits(bh)) {
      bitDiff++; if (firstBitDiff.equals("-")) firstBitDiff = tag + " T=" + t + " h=" + h;
    }
    if (lc != la) ctlDiff++;
    for (int i = 0; i < TH.length; i++) {
      double rt = repLog2(t, TH[i]), rh = repLog2(h, TH[i]);
      if ((int) (rt - rh) != la) thLevel[i]++;
      if (Double.doubleToRawLongBits(rt) != Double.doubleToRawLongBits(bt) || Double.doubleToRawLongBits(rh) != Double.doubleToRawLongBits(bh)) thBits[i]++;
    }
  }

  public static void main(String[] args) throws Exception {
    Arm base = new Arm("base", args[0]), cand = new Arm("candidate", args[1]);
    String rt = "java=" + System.getProperty("java.version") + " vm=" + System.getProperty("java.vm.name")
        + " arch=" + System.getProperty("os.arch")
        + " flags=" + java.lang.management.ManagementFactory.getRuntimeMXBean().getInputArguments();
    System.out.println("runtime  " + rt);
    System.out.println("base      " + base.source);
    System.out.println("candidate " + cand.source);
    if (base.bigArg || !cand.bigArg) { System.out.println("VERDICT VOID reflection control: expected base log2(double), candidate log2(BigInt)"); System.exit(3); }

    // 1. boundary rows (six targets, k = 1..40, 4097 doubles around T_f / 2^k)
    long[] nbits = {121307964L, 117500483L, 83925251L, 71994085L};
    List<BigInteger> targets = new ArrayList<>();
    for (long n : nbits) targets.add(Q.divide(decodeCompact(n)));
    targets.add(Q.divide(BigInteger.valueOf(24)));
    targets.add(BigInteger.ONE.shiftLeft(255));
    for (BigInteger t : targets) {
      double tf = t.doubleValue();
      for (int k = 1; k <= 40; k++) {
        long cb = Double.doubleToLongBits(Math.scalb(tf, -k));
        for (int off = -2048; off <= 2048; off++) {
          BigInteger h = new java.math.BigDecimal(Double.longBitsToDouble(cb + off)).toBigIntegerExact();
          row(base, cand, t, h, "boundary k=" + k + " off=" + off);
        }
      }
    }
    long bRows = rows, bLevel = levelDiff, bBits = bitDiff, bCtl = ctlDiff;
    System.out.println("boundary rows=" + bRows + " level_diff=" + bLevel + " bit_diff=" + bBits + " control_diff=" + bCtl);

    // 2. random pairs, seed 2332, bit lengths 1..256
    Random r = new Random(2332L);
    for (int i = 0; i < 1_000_000; i++) {
      BigInteger t = new BigInteger(1 + r.nextInt(256), r).setBit(0);
      BigInteger h = new BigInteger(1 + r.nextInt(256), r).setBit(0);
      row(base, cand, t, h, "random i=" + i);
    }
    System.out.println("random   rows=" + (rows - bRows) + " level_diff=" + (levelDiff - bLevel) + " bit_diff=" + (bitDiff - bBits));

    // 3. the PR's canary pairs (PoPowAlgosSpec, "level boundary is one of the known runtime classes")
    BigInteger t1 = new BigInteger("6970984169202524253037322628355088478036255079432670670749696");
    BigInteger h1 = new BigInteger("3403800863868407501259206016150990932074611810800886611968");
    BigInteger t2 = new BigInteger("22597575170739970084675297616952165580278685765328851259359232");
    BigInteger h2 = new BigInteger("10522815944040438093608276699383750648812778372988928");
    BigInteger h3 = new BigInteger("207751517570095187901637506342880669535499801197543424");
    BigInteger[][] cp = {{t1, h1}, {t2, h2}, {t1, h3}};
    StringBuilder tb = new StringBuilder(), tc = new StringBuilder();
    for (BigInteger[] p : cp) {
      tb.append((int) (base.lg(p[0]) - base.lg(p[1]))).append(',');
      tc.append((int) (cand.lg(p[0]) - cand.lg(p[1]))).append(',');
      row(base, cand, p[0], p[1], "canary");
    }
    String triple = tc.substring(0, tc.length() - 1);
    Map<String, String> classes = new LinkedHashMap<>();
    classes.put("11,30,25", "A"); classes.put("10,31,25", "B"); classes.put("11,30,24", "C");
    String cls = classes.getOrDefault(triple, "UNRECORDED");
    System.out.println("canary   base=(" + tb.substring(0, tb.length() - 1) + ") candidate=(" + triple + ") class=" + cls);

    Double ln2 = cand.ln2();
    double hot = 0; long hotBits = 0; boolean hotSame = true;
    for (int i = 0; i < 2_000_000; i++) { hot = Math.log(2 + (i >>> 31)); long bits = Double.doubleToRawLongBits(hot); if (i == 0) hotBits = bits; else if (bits != hotBits) hotSame = false; }
    System.out.println("ln2      candidate.Ln2=" + (ln2 == null ? "absent" : Long.toHexString(Double.doubleToRawLongBits(ln2)))
        + " Math.log(2)=" + Long.toHexString(hotBits) + " stable_in_loop=" + hotSame
        + " StrictMath.log(2)=" + Long.toHexString(Double.doubleToRawLongBits(StrictMath.log(2))));

    StringBuilder th = new StringBuilder("threshold replicas, level differences from base (bit differences from candidate):");
    for (int i = 0; i < TH.length; i++) th.append(' ').append(TH[i]).append('=').append(thLevel[i]).append(" (").append(thBits[i]).append(')');
    int i977 = TH.length - 1;
    th.append(thLevel[i977] == 0 && thBits[i977] == 0 ? " | replica control 977 == candidate: ok" : " | replica control 977 == candidate: FAILED, replica arms VOID");
    System.out.println(th);
    boolean ctlOk = !System.getProperty("os.arch").contains("64") || System.getProperty("os.arch").startsWith("aarch") || bCtl > 0;
    System.out.println("first_level_diff " + firstLevelDiff);
    System.out.println("first_bit_diff   " + firstBitDiff);
    String v = !ctlOk ? "VOID (positive control saw no difference)"
        : (levelDiff == 0 && bitDiff == 0 ? "SAME" : (levelDiff == 0 ? "BITS_DIFFER" : "LEVEL_DIFFERS"));
    System.out.println("VERDICT " + v + " rows=" + rows + " level_diff=" + levelDiff + " bit_diff=" + bitDiff
        + " canary=" + triple + " class=" + cls + " | " + rt);
    System.exit(v.equals("SAME") ? 0 : 1);
  }
}
