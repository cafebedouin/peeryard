// Parse.java: java -cp <node-jar> Parse.java <file.hex>...   (JDK 11+ single-file launch)
// Parses each payload with that jar's ErgoSyncInfoMessageSpec.parseBytesTry, the call
// scorex.core.network.Synchronizer.parseAndHandle makes on an incoming sync message, and prints Success or Failure.
import java.nio.file.*;
import org.ergoplatform.nodeView.history.*;

public class Parse {
  static byte[] unhex(String s) { s = s.trim(); byte[] b = new byte[s.length() / 2]; for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16); return b; }
  public static void main(String[] a) throws Exception {
    for (String f : a) {
      scala.util.Try<?> t = ErgoSyncInfoMessageSpec$.MODULE$.parseBytesTry(unhex(new String(Files.readAllBytes(Paths.get(f)))));
      if (t.isSuccess()) System.out.println(f + ": Success " + t.get().getClass().getSimpleName());
      else { Throwable e = ((scala.util.Failure<?>) t).exception(); System.out.println(f + ": Failure " + e.getClass().getName() + ": " + e.getMessage()); }
    }
  }
}
