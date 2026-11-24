# Craft Opportunities

## 3.4.0

- New **Time** column: each recipe's cast time.

## 3.3.3

- With TSM, the **Sales** filter is off while **Sell to a vendor (VendorSell)** is ticked under Pricing. Its settings
  are kept for when it is unticked.

## 3.3.2

- Fixed: since a recent client update no character was recorded, so the window stayed empty. WoW Forever has no realm
  names any more; characters are now grouped by ruleset and faction, as its auction houses are. Older records update
  on each character's next login.
- The market filter now reads **This ruleset and faction**.
- The Pricing panel no longer shows the note about auction house cuts with TSM.

## 3.3.1

- Recommendations now show as cards above the list, each with an **Install** button: Auctionator when neither it nor
  TSM is loaded, and SkillUp Forever when it is not. The SkillUp Forever card can be dismissed; its Install link then
  stays under Pricing.

## 3.3.0

- **SkillUp Forever is now optional.** Without it, the window lists the recipes your characters know, with materials
  and products from the game itself. Open each profession window once on each character to record its recipes.
  SkillUp Forever adds the recipes they could learn, the skill each needs and where to get it.
- Pricing shows an **Install** link for SkillUp Forever when it is not loaded, and for Auctionator when neither it nor
  TSM is.

## 3.2.0

Needs TSM's region data (TSM desktop app); without it nothing changes.

- **Sold/day** column (TSM region sold per day), sortable.
- **Sales** filter: sliders for minimum sold per day and sale rate, with the count left.

## 3.1.0

- New **Item type** filter: tick which kinds of product to list, by the auction house's categories (Weapon, Armor,
  Container, Consumable, Trade Goods and so on). Each type shows how many recipes it holds under the other filters.
  Untick Weapon and Armor to hide gear, whose listed prices it rarely sells for; the filter then reads *No gear*.
- A recipe's details show its product's item type, such as *Armor · Cloth* or *Container · Bag*.

## 3.0.0

**After updating, log in on each of your characters once** so Craft Opportunities can record their professions and
recipes again. Opening each profession once confirms its recipes. Character records from earlier versions are cleared.

- Characters that share a first name are now told apart. Craft Opportunities now keeps its own record of each
  character's professions and learned recipes, instead of reading SkillUp Forever's. SkillUp Forever still provides
  the recipe data.
- Characters always show by their full name, including in the row summaries.
- Without TradeSkillMaster, you now choose what crafts sell for in the Pricing panel: *Vendor price* (the default) or
  *Auction price if higher*, which needs Auctionator. SkillUp Forever's *Count what crafts sell for* setting is no
  longer used.

## 2.6.1

- With TradeSkillMaster, Refresh now picks up a price Auctionator recorded from a single item search. Before, TSM
  kept the old Auctionator price until a full scan.
- Calculating is faster: TSM's craft value overrides are read once per calculation, and more of each frame is used.
- Reopening the window keeps prices from the last few minutes, unless Auctionator has recorded a new price since.

## 2.6.0

First public release.

- Lists profitable crafts across all of your characters: recipes each one knows, and recipes it has the skill to
  learn, with material cost, estimated proceeds, profit and return on materials.
- Reads recipes and learned recipes through SkillUp Forever's addon API (SkillUp Forever v1.12.0 or later).
- Prices through TradeSkillMaster when it is installed, matching TSM's own crafting cost and profit by default, and
  otherwise by SkillUp Forever's rules with Auctionator's prices.
