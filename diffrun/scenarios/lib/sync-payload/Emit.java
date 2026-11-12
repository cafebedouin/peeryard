// Emit.java: java -cp <node-jar> Emit.java <out-dir>   (JDK 11+ single-file launch)
// Writes the sync-info payloads this jar's own ErgoSyncInfoMessageSpec produces, as hex:
//   v2.hex  ErgoSyncInfoV2(no headers)                                   (every node since 4.0.16 parses it)
//   v3.hex  ErgoSyncInfoV3(no headers, headers 1..100, full blocks 50..100), only if the jar has that class
// Prints "v2 <hex>", then "v3 <hex>" or "v3 absent". Reflection, so it runs on jars without ErgoSyncInfoV3.
import java.nio.file.*;
import java.util.*;
import org.ergoplatform.nodeView.history.*;
import scala.Tuple2;

public class Emit {
  static String hex(byte[] b) { StringBuilder s = new StringBuilder(); for (byte x : b) s.append(String.format("%02x", x)); return s.toString(); }
  @SuppressWarnings({"unchecked", "rawtypes"})
  static scala.collection.Seq seq(List l) { return ((scala.collection.mutable.Buffer) scala.collection.JavaConverters.asScalaBufferConverter(l).asScala()).toList(); }
  static void write(Path out, String name, ErgoSyncInfo si) throws Exception {
    String h = hex(ErgoSyncInfoMessageSpec$.MODULE$.toBytes(si));
    Files.write(out.resolve(name + ".hex"), h.getBytes());
    System.out.println(name + " " + h);
  }
  public static void main(String[] a) throws Exception {
    Path out = Paths.get(a[0]);
    scala.collection.Seq none = seq(new ArrayList());
    write(out, "v2", new ErgoSyncInfoV2(none));
    Class<?> v3;
    try { v3 = Class.forName("org.ergoplatform.nodeView.history.ErgoSyncInfoV3"); }
    catch (ClassNotFoundException e) { System.out.println("v3 absent"); return; }
    scala.collection.Seq hr = seq(Arrays.asList(new Tuple2<Object, Object>(1, 100)));
    scala.collection.Seq fr = seq(Arrays.asList(new Tuple2<Object, Object>(50, 100)));
    Object si = v3.getConstructor(scala.collection.Seq.class, scala.collection.Seq.class, scala.collection.Seq.class).newInstance(none, hr, fr);
    write(out, "v3", (ErgoSyncInfo) si);
  }
}
