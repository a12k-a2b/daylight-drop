import com.daylight.drop.transport.AndroidHttpServer;
import com.daylight.drop.transport.LoopSuppressionEngine;
import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.util.UUID;

public class KotlinServerRunner {
    public static void main(String[] args) throws Exception {
        int port = args.length > 0 ? Integer.parseInt(args[0]) : 8766;
        File tempDir = new File(System.getProperty("java.io.tmpdir"), "daylight_android_" + UUID.randomUUID());
        tempDir.mkdirs();
        LoopSuppressionEngine loop = new LoopSuppressionEngine("android-challenger-m1", 100, 60000L);
        AndroidHttpServer server = new AndroidHttpServer(port, "android-challenger-m1", tempDir, loop);
        server.setOnDropReceived((transferId, filename, type, file, sha256) -> {
            System.out.println("[SERVER_EVENT] DROP_RECEIVED id=" + transferId + " file=" + filename + " sha=" + sha256 + " size=" + file.length());
            System.out.flush();
            return kotlin.Unit.INSTANCE;
        });
        server.start();
        System.out.println("[SERVER_READY] port=" + port + " tempDir=" + tempDir.getAbsolutePath());
        System.out.flush();
        
        BufferedReader reader = new BufferedReader(new InputStreamReader(System.in));
        String line;
        while ((line = reader.readLine()) != null) {
            if ("STOP".equals(line.trim())) {
                break;
            }
        }
        server.stop();
        System.out.println("[SERVER_STOPPED]");
        System.out.flush();
    }
}
