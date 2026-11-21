# Craft Opportunities

Craft Opportunities is a WoW Forever addon that shows which crafts make a profit across all of your characters. It
covers the recipes each character knows and, with SkillUp Forever, the recipes it has the skill to learn. For each one
it lists material cost, estimated sale proceeds, profit and return on materials.

Craft Opportunities records each character's professions and learned recipes itself, and reads their materials and
products from the game. Prices come from TradeSkillMaster or Auctionator.

## Requirements

- The WoW Forever client.
- **Auctionator** or **TradeSkillMaster** (recommended) for auction prices, and for the vendor prices they have seen
  at merchants. With neither, only what a vendor pays for a product is known, so most profits are missing.
- **SkillUp Forever v1.12.0 or later** (optional) adds the recipes your characters could learn, with their learn
  requirements and where the recipe comes from. It needs **ForeverCore**.

## Install

1. Extract the `CraftOpportunities` folder into `World of Warcraft\_forever_\Interface\AddOns`.
2. Restart the game. A `/reload` does not pick up a new addon.
3. Log in on each character once and open each of its profession windows. Craft Opportunities records its
   professions, their levels and the recipes it knows. With SkillUp Forever it also reads the spellbook at login.

## Use

Open the window with `/craftops` or `/cops`, or from the minimap's addon compartment.

| Column | Meaning |
| --- | --- |
| Materials | the cost of one craft's materials |
| Est. proceeds | sale price x mean yield per craft |
| Est. profit | proceeds - materials |
| Return | proceeds / materials: 2.00x means a profit of 100% of the cost |
| Sold/day | TSM: region sold per day ([sales data](#sales-data)) |

With TSM sales data, orange lines flag two risks: under Est. proceeds, the region sale average per craft when it is
under 75% of the sale price; under Sold/day, "1 in N sell" when the sale rate is under 20% at 1+ a day.

Click **Est. profit**, **Return** or **Sold/day** to sort by it. Recipes without a full price come last.

Filters:

- **Character**: all characters, or one.
- **Profession**: a checkbox for each profession, with *Select all* and *Select none*.
- **Item type**: a checkbox for each kind of product, by the auction house's categories (Weapon, Armor, Container,
  Consumable, Trade Goods and so on), with *Select all* and *Select none*. Each shows how many recipes it holds under
  the other filters. Gear rarely sells at the price it is listed for: untick Weapon and Armor to hide it, and the
  filter reads *No gear*.
- **Availability** (SkillUp Forever): *Known or can learn* (the default), known only, can learn only, also higher skill needed, or
  everything.
- **Sales** (TSM): sliders for a minimum sold per day (has sold, 0.25 up to 100) and sale rate (5% to 60%); the menu
  shows how many recipes are left. [Sales data](#sales-data).
- **Profitable only**.
- **Search** (right end): the recipe name or the product's name.

Select a row for details: the product, its item type and mean yield, each character's state, every material with its
unit price and source, and the sale assumptions. With SkillUp Forever they also show the required skill and where the
recipe is learned, and when SkillUp knows where a recipe item comes from, its vendors, quests and drops.

Hover a row for the product's tooltip, and Shift-click it to link it in chat. Ctrl-click (Cmd-click on a Mac) a row,
item, vendor, quest or NPC to get its Wowhead address. The game cannot open a browser, so the address shows in a
small window, selected and ready for Ctrl+C.

### States

| State | Meaning |
| --- | --- |
| Known | The character has learned it. This is live for the current character, and as last recorded for others. |
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

**Without TSM**, the auction price is Auctionator's latest scan, and a material costs the cheaper of a vendor's price
and the auction price. What a product sells for is chosen under **Pricing > Products sell for**:

| Choice | A product sells for |
| --- | --- |
| Vendor price (the default) | its vendor sell price |
| Auction price if higher | its auction price less a 5% cut, or its vendor sell price if that is more |

*Auction price if higher* needs Auctionator; without it the choice cannot be picked, and vendor prices are used.

In both modes, owned and gathered materials are priced as bought, never free. A missing price stays unknown, never 0.
Recipes that make no item, or whose product is bind on pickup or a quest item, are not listed; the status line
counts them.

Not counted: recipe and training costs, auction deposits and relisting, undercutting, and time to sell. Yields are
SkillUp's mean yield, or without SkillUp the middle of the game's range.

## Sales data

From TSM's `DBRegionSoldPerDay`, `DBRegionSaleRate` and `DBRegionSaleAvg` (TSM desktop app). Without them the
window has no sales column or filter.

- **Sold per day** (column, filter): region-wide. Red under 1, yellow 1+, green 10+.
- **Sale rate** (filter, details, flag): share of postings that sell, e.g. 25% (1 in 4 posts).
- **Region sale average** (details, flag): what buyers paid.

## Storage

Craft Opportunities saves only its settings and a record for each character in `CraftOpportunitiesDB`, keyed by the
character's GUID: name, surname, realm, faction, profession levels and names, the recipes it knows, and when each
profession window was last fully recorded. Recipe data stays in SkillUp Forever or the game, and prices and sales data
in TSM or Auctionator.

The calculation runs a few milliseconds per frame, pauses in combat, and releases everything when the window closes.
Neither TSM nor Auctionator signals new prices, so click **Refresh** after a scan.

## Limitations

- Prices are the current character's market only.
- Another character's knowledge is as fresh as its last login.
- Reputation, specialisations, limited vendor stock and whether a recipe item can be obtained are not checked.
- No crafting queue; the window has a fixed size.

## License

MIT. See [LICENSE](LICENSE).
