import com.google.common.primitives.Ints;
import com.google.common.primitives.Longs;
import org.ergoplatform.mining.AutolykosPowScheme;

import java.math.BigInteger;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * A CPU miner for a devnet node in external-miner mode, using the node jar's own Autolykos v2 hit function.
 *
 * Why it exists: the node's internal miner mines with its wallet's first secret and ignores ergo.node.miningPubKeyHex,
 * and it serves a cached candidate only to a requester with the same key. An application that submits candidates
 * under another key (a Lithos client naming its collateral lender) therefore never sees them mined by the internal
 * miner. In external-miner mode the node mines with miningPubKeyHex, and this miner solves whatever candidate the
 * node holds, the application's included. Hashrate is a few thousand per second: devnet difficulty only.
 *
 * Usage: java -cp <out>:<ergo.jar> DevnetMiner --node http://127.0.0.1:9052 [--api-key hello] [--poll-ms 500]
 */
public final class DevnetMiner {
    public static void main(String[] args) throws Exception {
        String node = "http://127.0.0.1:9052", apiKey = "hello"; long pollMs = 500;
        for (int i = 0; i + 1 < args.length; i += 2) {
            switch (args[i]) {
                case "--node": node = args[i + 1].replaceAll("/+$", ""); break;
                case "--api-key": apiKey = args[i + 1]; break;
                case "--poll-ms": pollMs = Long.parseLong(args[i + 1]); break;
                default: throw new IllegalArgumentException("unknown option " + args[i]);
            }
        }
        HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();
        AutolykosPowScheme scheme = new AutolykosPowScheme(32, 26);
        Pattern pMsg = Pattern.compile("\"msg\"\\s*:\\s*\"([0-9a-f]+)\""), pB = Pattern.compile("\"b\"\\s*:\\s*([0-9]+)"),
                pH = Pattern.compile("\"h\"\\s*:\\s*([0-9]+)"), pPk = Pattern.compile("\"pk\"\\s*:\\s*\"([0-9a-f]+)\"");
        String current = ""; long nonce = 0; byte[] msg = null, hBytes = null; BigInteger b = null; String pk = null; int N = 0;
        long solved = 0;
        while (true) {
            String body;
            try {
                HttpResponse<String> r = http.send(HttpRequest.newBuilder(URI.create(node + "/mining/candidate"))
                        .header("api_key", apiKey).timeout(Duration.ofSeconds(10)).GET().build(), HttpResponse.BodyHandlers.ofString());
                body = r.body();
            } catch (Exception e) { log("candidate request failed: " + e.getMessage()); Thread.sleep(pollMs); continue; }
            Matcher mm = pMsg.matcher(body), mb = pB.matcher(body), mh = pH.matcher(body), mp = pPk.matcher(body);
            if (!(mm.find() && mb.find() && mh.find() && mp.find())) { log("no work: " + body.replace('\n', ' ')); Thread.sleep(pollMs); continue; }
            if (!mm.group(1).equals(current)) {
                current = mm.group(1); msg = hex(current); b = new BigInteger(mb.group(1)); int h = Integer.parseInt(mh.group(1));
                hBytes = Ints.toByteArray(h); pk = mp.group(1); N = scheme.calcN((byte) 2, h); nonce = 0;
                log("new work for height " + h + " msg " + current.substring(0, 8) + " pk " + pk.substring(0, 8));
            }
            scala.math.BigInt target = new scala.math.BigInt(b);
            long deadline = System.currentTimeMillis() + pollMs; boolean found = false;
            while (System.currentTimeMillis() < deadline && !found) {
                for (int i = 0; i < 200; i++, nonce++) {
                    byte[] nb = Longs.toByteArray(nonce);
                    if (scheme.hitForVersion2ForMessage(msg, nb, hBytes, N).compareTo(target) < 0) {
                        String sol = "{\"pk\":\"" + pk + "\",\"w\":\"" + pk + "\",\"n\":\"" + toHex(nb) + "\",\"d\":0}";
                        HttpResponse<String> r = http.send(HttpRequest.newBuilder(URI.create(node + "/mining/solution"))
                                .header("api_key", apiKey).header("Content-Type", "application/json")
                                .POST(HttpRequest.BodyPublishers.ofString(sol)).build(), HttpResponse.BodyHandlers.ofString());
                        solved++; log("solution nonce " + nonce + " -> " + r.statusCode() + " " + r.body().replace('\n', ' ') + " (solved " + solved + ")");
                        found = true; current = ""; break;
                    }
                }
            }
            if (!found) Thread.sleep(50);
        }
    }
    static void log(String s) { System.out.println(java.time.LocalTime.now().withNano(0) + " " + s); System.out.flush(); }
    static byte[] hex(String s) { byte[] out = new byte[s.length() / 2]; for (int i = 0; i < out.length; i++) out[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16); return out; }
    static String toHex(byte[] b) { StringBuilder sb = new StringBuilder(); for (byte x : b) sb.append(String.format("%02x", x)); return sb.toString(); }
}
