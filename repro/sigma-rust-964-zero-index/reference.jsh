// The reference node's hit and verdict on the same bytes: ergo v6.0.8 jar, AutolykosPowScheme(32, 26).
// Run: HEADERS=headers.hex jshell --class-path ergo-6.0.8.jar reference.jsh
byte[] hx(String s) { byte[] b = new byte[s.length() / 2]; for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16); return b; }
var ser = org.ergoplatform.modifiers.history.header.HeaderSerializer$.MODULE$;
var pow = new org.ergoplatform.mining.AutolykosPowScheme(32, 26);
for (String line : java.nio.file.Files.readAllLines(java.nio.file.Path.of(System.getenv("HEADERS")))) {
    String[] p = line.split(" ");
    var h = (org.ergoplatform.modifiers.history.header.Header) ser.parseBytes(hx(p[1]));
    System.out.println(p[0] + " height=" + h.height() + " validate=" + pow.validate(h) + " hit=" + pow.hitForVersion2(h));
}
/exit
