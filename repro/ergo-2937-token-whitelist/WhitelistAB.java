// Reads the same HOCON settings through one ergo node jar's ErgoSettingsReader.fromConfig and prints one CASE line per
// input: whether the settings were read, the two token whitelists and blacklistedTransactions as read, or the exception
// (class and message) and the first org.ergoplatform frame it was thrown from. The input is parsed and laid over the
// jar's own application.conf and reference.conf (ConfigFactory.load()), the way ErgoSettingsSpecification reads settings.
// Run once per jar, with only that jar (and this class) on the class path:
//   javac -cp <jar> -d <out> WhitelistAB.java && java -cp <out>:<jar> WhitelistAB
// Exit status 0 when every case printed a line; 2 on a setup failure.
import com.typesafe.config.Config;
import com.typesafe.config.ConfigFactory;
import org.ergoplatform.settings.ErgoSettings;
import org.ergoplatform.settings.ErgoSettingsReader;

import java.util.ArrayList;
import java.util.List;

public class WhitelistAB {
  static final String SIGUSD = "03faf2cb329f2e90d6d23b58d91bbb6c046aa143261cc21f52fbe2824bfcbf04";
  static final String ID2 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
  static final String W = "ergo.wallet.tokensWhitelist";
  static final String N = "ergo.node.storageRentTokenWhitelist";
  static final String B = "ergo.node.blacklistedTransactions";

  static String q(String s) { return "\"" + s + "\""; }

  // a list as read: its size, then each element in single quotes (so an empty string shows as '')
  static String fmt(scala.collection.Seq<String> xs) {
    StringBuilder b = new StringBuilder("[" + xs.size() + ":");
    scala.collection.Iterator<String> it = xs.iterator();
    String sep = "";
    while (it.hasNext()) { b.append(sep).append("'").append(it.next()).append("'"); sep = ","; }
    return b.append("]").toString();
  }

  // one malformed-or-valid entry set, applied to either whitelist key
  static String[][] entries() {
    String oneCap = "03FAf2cb329f2e90d6d23b58d91bbb6c046aa143261cc21f52fbe2824bfcbf04"; // two capital letters
    return new String[][]{
      {"valid1", "[" + q(SIGUSD) + "]"},
      {"valid2", "[" + q(SIGUSD) + ", " + q(ID2) + "]"},
      {"dup-valid", "[" + q(SIGUSD) + ", " + q(SIGUSD) + "]"},
      {"example", "[" + q("example") + "]"},
      {"empty-string", "[" + q("") + "]"},
      {"upper", "[" + q(SIGUSD.toUpperCase()) + "]"},
      {"two-capitals", "[" + q(oneCap) + "]"},
      {"len63", "[" + q(SIGUSD.substring(0, 63)) + "]"},
      {"len65", "[" + q(SIGUSD + "0") + "]"},
      {"non-hex-g", "[" + q(SIGUSD.substring(0, 63) + "g") + "]"},
      {"leading-space", "[" + q(" " + SIGUSD) + "]"},
      {"0x-prefix", "[" + q("0x" + SIGUSD) + "]"},
      {"hocon-number", "[123]"},
      {"mixed", "[" + q(SIGUSD) + ", " + q("example") + ", " + q(ID2.toUpperCase()) + ", " + q("example") + "]"},
    };
  }

  public static void main(String[] args) throws Exception {
    List<String[]> cases = new ArrayList<>();
    cases.add(new String[]{"DEFAULT", ""});
    cases.add(new String[]{"W-null", W + " = null"});
    cases.add(new String[]{"W-empty-list", W + " = []"});
    for (String[] e : entries()) cases.add(new String[]{"W-" + e[0], W + " = " + e[1]});
    cases.add(new String[]{"W-string-not-list", W + " = " + q("example")});
    cases.add(new String[]{"N-empty-list", N + " = []"});
    for (String[] e : entries()) cases.add(new String[]{"N-" + e[0], N + " = " + e[1]});
    cases.add(new String[]{"BOTH-example", W + " = [" + q("example") + "]\n" + N + " = [" + q("example") + "]"});
    cases.add(new String[]{"BLACKLIST-example", B + " = [" + q("example") + "]"});

    String src = ErgoSettingsReader.class.getProtectionDomain().getCodeSource().getLocation().getPath();
    System.out.println("JAR " + src.substring(src.lastIndexOf('/') + 1));
    int printed = 0;
    for (String[] c : cases) {
      String result;
      try {
        Config cfg = ConfigFactory.parseString(c[1]).withFallback(ConfigFactory.load());
        ErgoSettings s = ErgoSettingsReader.fromConfig(cfg, scala.Option.empty());
        scala.Option<scala.collection.Seq<String>> w = s.walletSettings().tokensWhitelist();
        result = "read wallet=" + (w.isDefined() ? fmt(w.get()) : "None")
          + " rent=" + fmt(s.nodeSettings().storageRentTokenWhitelist())
          + " blacklist=" + fmt(s.nodeSettings().blacklistedTransactions());
      } catch (Throwable t) {
        String at = "-";
        for (StackTraceElement f : t.getStackTrace()) {
          if (f.getClassName().startsWith("org.ergoplatform.")) { at = f.getClassName() + "." + f.getMethodName(); break; }
        }
        String msg = String.valueOf(t.getMessage()).replace('\n', ' ');
        result = "rejected " + t.getClass().getSimpleName() + ": " + msg + " at=" + at;
      }
      System.out.println("CASE " + c[0] + " " + result);
      printed++;
    }
    System.out.println("CASES " + printed);
    System.exit(printed == cases.size() ? 0 : 2);
  }
}
