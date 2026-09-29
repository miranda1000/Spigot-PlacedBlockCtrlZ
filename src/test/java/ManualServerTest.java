import dev.watchwolf.core.entities.Position;
import dev.watchwolf.core.entities.blocks.Block;
import dev.watchwolf.core.entities.items.Item;
import dev.watchwolf.core.entities.items.ItemType;
import dev.watchwolf.tester.ExtendedClientPetition;
import dev.watchwolf.tester.ServerSetupException;
import dev.watchwolf.tester.TesterConnector;
import org.junit.jupiter.api.extension.AfterAllCallback;
import org.junit.jupiter.api.extension.BeforeAllCallback;
import org.junit.jupiter.api.extension.ExtensionContext;
import org.junit.jupiter.api.extension.ParameterContext;
import org.junit.jupiter.api.extension.ParameterResolutionException;
import org.junit.jupiter.api.extension.ParameterResolver;
import org.junit.jupiter.api.extension.TestWatcher;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.util.UUID;

/**
 * Stands in for {@code dev.watchwolf.tester.AbstractTest} when the Minecraft server under test is
 * started by hand (see {@code ci-manual/2-start-server.sh}) instead of by WatchWolf-ServersManager
 * -- and, unlike a ServersManager-launched server, carries no WatchWolf-Server dispatcher plugin
 * either. This harness only ever talks to WatchWolf-ClientsManager and the bots it spawns.
 *
 * <p>Concretely, that means every {@code ServerPetition} method on {@link TesterConnector}
 * ({@code setBlock}, {@code giveItem}, {@code setDifficulty}, ...) is unusable: they all silently
 * no-op, because they require a dispatcher socket ({@code TesterConnector#setServerManagerSocket})
 * this class never sets. Tests reach the same things through a vanilla command run by one of the
 * bots instead -- see {@link #runCommand}, {@link #setBlock}, {@link #giveItem} and
 * {@link #isBlock} below. That's also why {@code ci-manual/2-start-server.sh} ops the bot usernames
 * up front (in {@code ops.json}): vanilla commands like {@code /give} and {@code /setblock} need
 * permission level 2.</p>
 *
 * <p>Connection details are read from the environment (defaults match
 * {@code ci-manual/2-start-server.sh} and {@code ci-manual/3-start-clients-manager.sh}):</p>
 * <ul>
 *   <li>{@code WATCHWOLF_SERVER_HOST} -- Minecraft server host (default {@code 127.0.0.1})</li>
 *   <li>{@code WATCHWOLF_SERVER_PORT} -- Minecraft server port (default {@code 25565})</li>
 *   <li>{@code WATCHWOLF_CLIENTSMANAGER_HOST} -- ClientsManager host (default {@code WATCHWOLF_SERVER_HOST})</li>
 *   <li>{@code WATCHWOLF_CLIENTSMANAGER_PORT} -- ClientsManager port (default {@code 7000})</li>
 * </ul>
 *
 * <p>Test methods are plain {@code @Test} methods taking a {@link TesterConnector} parameter,
 * resolved via {@link ParameterResolver} on this same extension instance -- no
 * {@code ArgumentsProvider}, no static instance-tracking map (see git history for why that would
 * otherwise be needed).</p>
 */
public abstract class ManualServerTest implements TestWatcher,
        BeforeAllCallback, AfterAllCallback, // connect/disconnect
        ParameterResolver { // hand test methods the connector

    public static final int CONNECT_TIMEOUT = 15_000;

    private static final String SERVER_HOST = envOr("WATCHWOLF_SERVER_HOST", "127.0.0.1");
    private static final int SERVER_PORT = Integer.parseInt(envOr("WATCHWOLF_SERVER_PORT", "25565"));
    private static final String CLIENTS_MANAGER_HOST = envOr("WATCHWOLF_CLIENTSMANAGER_HOST", SERVER_HOST);
    private static final int CLIENTS_MANAGER_PORT = Integer.parseInt(envOr("WATCHWOLF_CLIENTSMANAGER_PORT", "7000"));

    private TesterConnector connector;
    private UUID testID;

    private static String envOr(String name, String defaultValue) {
        String value = System.getenv(name);
        return (value == null || value.isEmpty()) ? defaultValue : value;
    }

    @Override
    public void beforeAll(ExtensionContext extensionContext) throws IOException {
        this.testID = UUID.randomUUID();
        String[] users = this.getUsers();

        System.out.println("[manual] Connecting to ClientsManager " + CLIENTS_MANAGER_HOST + ":" + CLIENTS_MANAGER_PORT
                + " using ID " + this.testID);

        Socket clientsManagerSocket = this.connect(CLIENTS_MANAGER_HOST, CLIENTS_MANAGER_PORT,
                "the ClientsManager (is ci-manual/3-start-clients-manager.sh running?)");

        // We never talk to a ServersManager, and the server has no WatchWolf-Server dispatcher
        // plugin either (see ci-manual/2-start-server.sh) -- this socket is never connected and
        // never read from. TesterConnector just needs a non-null Socket to build and close
        // cleanly; every ServerPetition method silently no-ops without a dispatcher socket, so
        // this class never calls them -- see the command-based helpers below instead.
        Socket unusedServersManagerSocket = new Socket();

        this.connector = new TesterConnector(unusedServersManagerSocket, clientsManagerSocket, this.getOverrideSync());
        this.connector.setExpectedClients(users);

        try {
            this.connectClients(users);
        } catch (Throwable ex) {
            this.connector.close();
            this.connector = null;
            throw ex;
        }

        this.beforeAll(this.connector);
    }

    /** Asks ClientsManager to spawn and connect every user. There's no whitelist to wait on --
     * {@code ci-manual/2-start-server.sh} sets {@code white-list=false} -- so bots can join as
     * soon as they're started. */
    private void connectClients(String[] users) throws IOException {
        int clientNumber = 0;
        for (String user : users) {
            clientNumber++;
            System.out.println("[manual] Starting client " + clientNumber + "/" + users.length + " ('" + user + "')...");

            String ip;
            try {
                ip = this.connector.startClient(user, SERVER_HOST + ":" + SERVER_PORT);
            } catch (IOException | RuntimeException ex) {
                throw new ServerSetupException(null, null,
                        "failed to ask the ClientsManager for '" + user + "' (" + ex.getMessage() + ").", ex);
            }
            if (ip == null || ip.isEmpty()) {
                throw new ServerSetupException(null, null,
                        "the ClientsManager could not start '" + user + "' on " + SERVER_HOST + ":" + SERVER_PORT
                        + ". The bot never joined -- check the ClientsManager log and that the server is up "
                        + "(ci-manual/2-start-server.sh).");
            }

            String[] clientIp = ip.split(":");
            if (clientIp.length != 2) {
                throw new ServerSetupException(null, null,
                        "the ClientsManager answered with '" + ip + "' for '" + user + "', which is not an <ip>:<port> address.");
            }

            System.out.println("[manual] Connecting to " + ip + " (client '" + user + "')...");
            Socket clientSocket = this.connect(clientIp[0], Integer.parseInt(clientIp[1]), "client '" + user + "'");
            this.connector.setClientSocket(clientSocket, user);
        }
    }

    /**
     * Opens a socket within {@link #CONNECT_TIMEOUT}, saying what we were trying to reach when it
     * does not answer.
     */
    private Socket connect(String host, int port, String what) {
        Socket socket = new Socket();
        try {
            socket.connect(new InetSocketAddress(host, port), CONNECT_TIMEOUT);
            return socket;
        } catch (IOException ex) {
            try { socket.close(); } catch (IOException ignore) {}
            throw new ServerSetupException(null, null,
                    "could not reach " + what + " at " + host + ":" + port + " (" + ex.getMessage() + ").", ex);
        }
    }

    /**
     * This method will run just once, at the start. Use it to setup all the tests (e.g. position
     * one player to a specific place, or giving him items)
     * @param server The connector to the already-running server
     */
    public void beforeAll(TesterConnector server) throws IOException {}

    @Override
    public void afterAll(ExtensionContext extensionContext) throws IOException {
        if (this.connector == null) return; // the setup never got far enough to start anything
        this.afterAll(this.connector); // let the test close before we disconnect
        this.connector.close(); // bots disconnect when their sockets close
    }

    /**
     * This method will run just once, at the end. Use it to release resources acquired in the
     * overridden {@link #beforeAll(TesterConnector)}.
     * @param server The connector to the already-running server
     */
    public void afterAll(TesterConnector server) throws IOException {}

    @Override
    public void testSuccessful(ExtensionContext context) {
        System.err.println("Test " + context.getDisplayName() + " succeed");
    }

    @Override
    public void testFailed(ExtensionContext context, Throwable cause) {
        System.err.println("Test " + context.getDisplayName() + " failed: " + cause.getMessage());
    }

    @Override
    public boolean supportsParameter(ParameterContext parameterContext, ExtensionContext extensionContext) throws ParameterResolutionException {
        return parameterContext.getParameter().getType() == TesterConnector.class;
    }

    @Override
    public Object resolveParameter(ParameterContext parameterContext, ExtensionContext extensionContext) throws ParameterResolutionException {
        // Same extension instance beforeAll ran on -- no lookup needed.
        return this.connector;
    }

    /**
     * The bot usernames to connect before any {@code @Test} runs. If your tests use
     * {@link #setBlock}/{@link #giveItem}/{@link #isBlock}, these must also be listed in
     * {@code OP_USERS} when running {@code ci-manual/2-start-server.sh}.
     */
    protected abstract String[] getUsers();

    /** Passed straight to {@link TesterConnector}'s constructor. Default: {@code false}. */
    protected boolean getOverrideSync() { return false; }

    /* ---------------------------------------------------------------------------------------- *
     * Vanilla-command helpers, standing in for the ServerPetition methods (setBlock, giveItem,
     * getBlock...) that would normally go through a WatchWolf-Server dispatcher. There's no
     * dispatcher here, so these do the same job through a command run by one of the bots -- which
     * is why that bot needs to be opped (OP_USERS in ci-manual/2-start-server.sh).
     * ---------------------------------------------------------------------------------------- */

    /** Runs {@code command} as {@code onBehalfOf} and returns whatever feedback the bot receives. */
    protected static String runCommand(ExtendedClientPetition onBehalfOf, String command) throws IOException {
        return onBehalfOf.runCommand(command);
    }

    /** {@code /setblock <pos> <block>}, run as {@code onBehalfOf}. */
    protected static void setBlock(ExtendedClientPetition onBehalfOf, Position pos, Block block) throws IOException {
        runCommand(onBehalfOf, "setblock " + coords(pos) + " " + minecraftId(block.getItemType()));
    }

    /** {@code /give <player> <item> <amount>}, run as {@code onBehalfOf}. */
    protected static void giveItem(ExtendedClientPetition onBehalfOf, String player, Item item) throws IOException {
        runCommand(onBehalfOf, "give " + player + " " + minecraftId(item.getType()) + " " + item.getAmount());
    }

    /**
     * Whether the block at {@code pos} is currently {@code block}. Runs
     * {@code /execute if block <pos> <block> run tellraw @s <marker>} and looks for the marker in
     * the system feedback {@link #runCommand} returns. {@code say} produces player chat, which
     * the Client forwards separately and does not include in command feedback.
     */
    protected static boolean isBlock(ExtendedClientPetition onBehalfOf, Position pos, Block block) throws IOException {
        String marker = "watchwolf-check-" + UUID.randomUUID();
        String result = runCommand(onBehalfOf,
                "execute if block " + coords(pos) + " " + minecraftId(block.getItemType())
                        + " run tellraw @s {\"text\":\"" + marker + "\"}");
        return result != null && result.contains(marker);
    }

    private static String coords(Position pos) {
        return (int) Math.floor(pos.getX()) + " " + (int) Math.floor(pos.getY()) + " " + (int) Math.floor(pos.getZ());
    }

    private static String minecraftId(ItemType type) {
        return "minecraft:" + type.name().toLowerCase();
    }
}
