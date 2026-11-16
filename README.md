# Craft Opportunities

Craft Opportunities is a WoW Forever addon that shows which crafts make a profit across all of your characters. It
covers the recipes each character knows, and the recipes it has the skill to learn. For each one it lists material
cost, estimated sale proceeds, profit and return on materials.

Recipes, reagents, learn requirements and each character's learned recipes come from
[SkillUp Forever](https://github.com/cjber/skillup-forever). Prices come from TradeSkillMaster or Auctionator.

## Requirements

- The WoW Forever client.
- **SkillUp Forever v1.12.0 or later**, for its addon API for recipes and characters (`Recipes`, `Recipe`,
  `RecipeRequirement`, `Characters` and `Knows`), and **ForeverCore**, which SkillUp needs.
- Optional: **TradeSkillMaster** or **Auctionator** for auction prices, and for the vendor prices they have seen at
  merchants. With neither, only what a vendor pays for a product is known, so most profits are missing.

## Install

1. Extract the `CraftOpportunities` folder into `World of Warcraft\_forever_\Interface\AddOns`.
2. Restart the game. A `/reload` does not pick up a new addon.
3. Log in on each character once and open each of its professions. SkillUp Forever records the learned recipes, and
   Craft Opportunities records the character's profession levels.

## Use

Open the window with `/craftops` or `/cops`, or from the minimap's addon compartment.

| Column | Meaning |
| --- | --- |
| Materials | the cost of one craft's materials |
| Est. proceeds | sale price x mean yield per craft |
| Est. profit | proceeds - materials |
| Return | proceeds / materials: 2.00x means a profit of 100% of the cost |

Click **Est. profit** or **Return** to sort by it. Recipes without a full price come last.

Filters:

- **Character**: all characters, or one.
- **Profession**: a checkbox for each profession, with *Select all* and *Select none*.
- **Availability**: *Known or can learn* (the default), known only, can learn only, also higher skill needed, or
  everything.
- **Search**: the recipe name or the product's name.
- **Profitable only**.

Select a row for details: the product and mean yield, the required skill and where the recipe is learned, each
character's state, every material with its unit price and source, and the sale assumptions. When SkillUp Forever
knows where a recipe item comes from, the details list its vendors, quests and drops.

Hover a row for the product's tooltip, and Shift-click it to link it in chat. Ctrl-click (Cmd-click on a Mac) a row,
item, vendor, quest or NPC to get its Wowhead address. The game cannot open a browser, so the address shows in a
small window, selected and ready for Ctrl+C.

### States

| State | Meaning |
| --- | --- |
| Known | The character has learned it. This is live for the current character, and as SkillUp last recorded it for others. |
| Can learn | The character's base skill meets the recipe's trainer or recipe-item requirement. The recipe item, trainer, reputation or a specialisation may still be needed. |
| Higher skill needed | The character has the profession, below the requirement. |
| Not scanned / unknown | The requirement is unknown, or the character's profession levels were never recorded. |

An unknown requirement is never treated as 0.

### Characters and markets

By default only characters on the current character's realm and faction are compared, because auction prices are
that market's. **Pricing > All recorded characters** includes the rest, still priced at the current market.
Characters show by their full name, surname included.

## Pricing

**With TradeSkillMaster**, everything is priced through TSM. By default the figures match TSM's own tooltip line,
*Crafting Cost (profit)*:

- materials at TSM's material cost: `first(MatPrice, <TSM's default material cost method>)`;
- sales at TSM's craft value for the item: a Crafting operation's override, else TSM's default craft value method.

As in TSM, no auction house cut is taken on top; a sale expression carries its own (TSM's default craft value includes
`* 0.95`). Pricing lets you set your own material and sale expressions, choose whether a cheaper vendor price
replaces a material's TSM price, or value sales at `VendorSell`.

**Without TSM**, prices follow SkillUp Forever's own rules. The auction price is Auctionator's latest scan, and a
material costs the cheaper of a vendor's price and the auction price. What a product sells for follows SkillUp's
*Count what crafts sell for* setting:

| SkillUp's setting | A product sells for |
| --- | --- |
| Vendor sell price (the default) | its vendor sell price |
| Auction price if higher | its auction price less a 5% cut, or its vendor sell price if that is more |
| Don't count it | nothing: the window explains instead of listing unpriced recipes |

Change it in SkillUp Forever's settings, then click **Refresh**.

In both modes, owned and gathered materials are priced as bought, never free. A missing price stays unknown, never 0.
Recipes that make no item, or whose product is bind on pickup or a quest item, are not listed; the status line
counts them.

Not counted: recipe and training costs, auction deposits and relisting, undercutting, and time to sell. Yields are
SkillUp's mean yield.

## Storage

Craft Opportunities saves only its settings and a little metadata for each character in `CraftOpportunitiesDB`:
realm, faction, surname, profession levels and profession names, and when each profession window was last fully
recorded. Recipes and learned recipes stay in SkillUp Forever, and prices in TSM or Auctionator.

The calculation runs a few milliseconds per frame, pauses in combat, and releases everything when the window closes.
Neither TSM nor Auctionator signals new prices, so click **Refresh** after a scan.

## Limitations

- Prices are the current character's market only.
- Another character's knowledge is as fresh as SkillUp's last record of it.
- Reputation, specialisations, limited vendor stock and whether a recipe item can be obtained are not checked.
- SkillUp keys characters by first name and realm, so two characters on one realm with the same first name share a
  record.
- No crafting queue; the window has a fixed size.

## License

MIT. See [LICENSE](LICENSE).
