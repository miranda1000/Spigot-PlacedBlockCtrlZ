import dev.watchwolf.core.entities.Position;
import dev.watchwolf.core.entities.blocks.Block;
import dev.watchwolf.core.entities.blocks.Blocks;
import dev.watchwolf.core.entities.items.Item;
import dev.watchwolf.core.entities.items.ItemType;
import dev.watchwolf.tester.ExtendedClientPetition;
import dev.watchwolf.tester.TesterConnector;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

import java.io.IOException;
import java.util.HashMap;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * All the tests that we expect to fulfill the plugin's requirements.
 *
 * This extends {@link ManualServerTest} instead of WatchWolf-Tester's own {@code AbstractTest}:
 * these tests run against a Minecraft server you start yourself with
 * {@code ci-manual/2-start-server.sh}, which has no WatchWolf-Server dispatcher plugin on it
 * either -- see that script, and {@link ManualServerTest}'s Javadoc, for details. In practice that
 * means the "prepare the environment"/"give the client items" steps below go through
 * {@link ManualServerTest#setBlock}/{@link ManualServerTest#giveItem} (a command run by a bot)
 * instead of {@code connector.server.setBlock}/{@code connector.server.giveItem}.
 */
@ExtendWith(PlacedBlockCtrlZShould.class)
public class PlacedBlockCtrlZShould extends ManualServerTest {
    @Override
    protected String[] getUsers() {
        return new String[] {"user1"};
    }

    @BeforeEach
    public void prepareWorld(TesterConnector connector) throws IOException {
        ExtendedClientPetition operator = connector.getClientPetition(connector.getClients()[0]);
        // Dirt beside the superflat world's grass can change material before undo runs.
        runCommand(operator, "gamerule randomTickSpeed 0");
        // The manually started server persists player inventories between test runs.
        for (String user : connector.getClients()) {
            runCommand(operator, "clear " + user);
        }
    }

    /**
     * We'll place one dirt block, run the ctrl-z command, and then there should be air in that place
     * and the player should have his block back.
     */
    @Test
    public void restoreTheLastBrokenBlock(TesterConnector connector) throws IOException {
        /* decide where/who will interact with the event */
        String client = connector.getClients()[0];
        ExtendedClientPetition clientConnector = connector.getClientPetition(client);
        Position whereToPlaceTheBlock = clientConnector.getPosition().add(1,0,0); // block next to the user
        Block whatBlockWillBePlaced = Blocks.DIRT;

        /* prepare the environment (make sure the player can place the block there) */
        setBlock(clientConnector, whereToPlaceTheBlock, Blocks.AIR);

        /* prepare the client (give him the block to place) */
        Item placedBlockItem = new Item(whatBlockWillBePlaced.getItemType());
        giveItem(clientConnector, client, placedBlockItem);

        /* start the test */
        clientConnector.setBlock(whatBlockWillBePlaced, whereToPlaceTheBlock); // place the block
        assertTrue(isBlock(clientConnector, whereToPlaceTheBlock, whatBlockWillBePlaced),
                "The bot did not place the dirt block; cannot test undo.");
        clientConnector.runCommand("ctrl-z"); // undo

        assertTrue(isBlock(clientConnector, whereToPlaceTheBlock, Blocks.AIR)); // we expect air in the place we've put the block
        HashMap<ItemType, Integer> inventory = getItemAmounts(clientConnector.getInventory().getItems());
        assertEquals(1, inventory.getOrDefault(whatBlockWillBePlaced.getItemType(), 0).intValue(),
                "Expected one dirt block after undo; inventory was " + inventory);
    }

    /**
     * Given a container items it returns all the found items and the amount
     * @param items All the items in the container
     * @return {DIRT:2,WHEAT:6,...}
     */
    private static HashMap<ItemType,Integer> getItemAmounts(Item ...items) {
        HashMap<ItemType,Integer> r = new HashMap<>();

        for (Item i : items) {
            if (i == null) continue;

            Integer acum = r.get(i.getType());
            if (acum == null) r.put(i.getType(), (int)i.getAmount());
            else r.put(i.getType(), acum + i.getAmount());
        }

        return r;
    }
}
